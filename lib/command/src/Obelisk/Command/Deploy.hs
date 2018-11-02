{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
module Obelisk.Command.Deploy where

import Control.Lens
import Control.Monad
import Control.Monad.Catch (Exception (displayException), MonadThrow, throwM, try)
import Control.Monad.IO.Class (liftIO)
import Data.Bits
import Data.Default
import Data.List (isSuffixOf)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.Directory
import System.Environment (getEnvironment)
import System.FilePath
import System.Posix.Files
import System.Process (delegate_ctlc, env, proc, readCreateProcess, cwd)
import Text.URI (URI)
import qualified Text.URI as URI
import Text.URI.Lens

import Obelisk.App (MonadObelisk)
import Obelisk.CliApp (Severity (..), callProcessAndLogOutput, failWith, putLog, withSpinner)
import Obelisk.Command.Nix
import Obelisk.Command.Project
import Obelisk.Command.Thunk
import Obelisk.Command.Utils

deployInit
  :: MonadObelisk m
  => ThunkPtr
  -> FilePath
  -> FilePath
  -> FilePath
  -> [String] -- ^ hostnames
  -> String -- ^ route
  -> String -- ^ admin email
  -> Bool -- ^ enable https
  -> m ()
deployInit thunkPtr configDir deployDir sshKeyPath hostnames route adminEmail enableHttps = do
  (hasConfigDir, localKey) <- withSpinner ("Preparing " <> T.pack deployDir) $ do
    hasConfigDir <- liftIO $ do
      createDirectoryIfMissing True deployDir
      doesDirectoryExist configDir
    localKey <- liftIO (doesFileExist sshKeyPath) >>= \case
      False -> failWith $ T.pack $ "ob deploy init: file does not exist: " <> sshKeyPath
      True -> pure $ deployDir </> "ssh_key"
    callProcessAndLogOutput (Notice, Error) $
      proc "cp" [sshKeyPath, localKey]
    liftIO $ setFileMode localKey $ ownerReadMode .|. ownerWriteMode
    return $ (hasConfigDir, localKey)
  withSpinner "Validating configuration" $ do
    void $ getHostFromRoute enableHttps route -- make sure that hostname is present
  forM_ hostnames $ \hostname -> do
    putLog Notice $ "Verifying host keys (" <> T.pack hostname <> ")"
    -- Note: we can't use a spinner here as this function will prompt the user.
    verifyHostKey (deployDir </> "backend_known_hosts") localKey hostname
  when hasConfigDir $ withSpinner "Importing project configuration" $ do
    callProcessAndLogOutput (Notice, Error) $
      proc "cp" [ "-r" , "-T" , configDir , deployDir </> "config"]
  withSpinner "Writing deployment configuration" $ do
    writeDeployConfig deployDir "backend_hosts" $ unlines hostnames
    writeDeployConfig deployDir "enable_https" $ show enableHttps
    writeDeployConfig deployDir "admin_email" adminEmail
    writeDeployConfig deployDir ("config" </> "common" </> "route") $ route
  withSpinner "Creating source thunk (./src)" $ liftIO $ do
    createThunk (deployDir </> "src") thunkPtr
    setupObeliskImpl deployDir
  withSpinner ("Initializing git repository (" <> T.pack deployDir <> ")") $
    initGit deployDir

setupObeliskImpl :: FilePath -> IO ()
setupObeliskImpl deployDir = do
  let implDir = toImplDir deployDir
  createDirectoryIfMissing True implDir
  writeFile (implDir </> "default.nix") "(import ../../src {}).obelisk"

deployPush :: MonadObelisk m => FilePath -> m [String] -> m ()
deployPush deployPath getNixBuilders = do
  host <- readDeployConfig deployPath "backend_hosts"
  adminEmail <- readDeployConfig deployPath "admin_email"
  enableHttps <- read <$> readDeployConfig deployPath "enable_https"
  route <- readDeployConfig deployPath $ "config" </> "common" </> "route"
  routeHost <- getHostFromRoute enableHttps route
  let srcPath = deployPath </> "src"
  thunkPtr <- readThunk srcPath >>= \case
    Right (ThunkData_Packed ptr) -> return ptr
    Right (ThunkData_Checkout _) -> do
      checkGitCleanStatus srcPath True >>= \case
        True -> packThunk srcPath
        False -> failWith $ T.pack $ "ob deploy push: ensure " <> srcPath <> " has no pending changes and latest is pushed upstream."
    Left err -> failWith $ "ob deploy push: couldn't read src thunk: " <> T.pack (show err)
  let version = show . _thunkRev_commit $ _thunkPtr_rev thunkPtr
  builders <- getNixBuilders
  buildOutput <- nixCmd $ NixCmd_Build $ def
    & nixCmdConfig_target .~Target
      { _target_path = Just srcPath
      , _target_attr = Just "server.system"
      , _target_expr = Nothing
      }
    & nixBuildConfig_outLink .~ OutLink_None
    & nixCmdConfig_args .~
      [ strArg "hostName" host
      , strArg "adminEmail" adminEmail
      , strArg "routeHost" routeHost
      , strArg "version" version
      , boolArg "enableHttps" enableHttps
      , rawArg "config" $ deployPath </> "config"
      ]
    & nixCmdConfig_builders .~ builders
  let result = listToMaybe $ lines buildOutput
  forM_ result $ \res -> do
    let knownHostsPath = deployPath </> "backend_known_hosts"
        sshOpts = sshArgs knownHostsPath (deployPath </> "ssh_key") False
        deployAndSwitch outputPath = do
          withSpinner "Uploading closure" $ do
            callProcess'
              (Map.fromList [("NIX_SSHOPTS", unwords sshOpts)])
              "nix-copy-closure" ["-v", "--to", "root@" <> host, "--gzip", outputPath]

          withSpinner "Switching to new configuration" $ do
            callProcessAndLogOutput (Notice, Warning) $
              proc "ssh" $ sshOpts <>
                [ "root@" <> host
                , unwords
                    [ "nix-env -p /nix/var/nix/profiles/system --set " <> outputPath
                    , "&&"
                    , "/nix/var/nix/profiles/system/bin/switch-to-configuration switch"
                    ]
                ]
    deployAndSwitch res
    isClean <- checkGitCleanStatus deployPath True
    when (not isClean) $ do
      withSpinner "Commiting changes to Git" $ do
        callProcessAndLogOutput (Debug, Error) $ proc "git"
          ["-C", deployPath, "add", "."]
        callProcessAndLogOutput (Debug, Error) $ proc "git"
          ["-C", deployPath, "commit", "-m", "New deployment"]
    putLog Notice $ "Deployed => " <> T.pack route
  where
    callProcess' envMap cmd args = do
      processEnv <- Map.toList . (envMap <>) . Map.fromList <$> liftIO getEnvironment
      let p = (proc cmd args) { delegate_ctlc = True, env = Just processEnv }
      callProcessAndLogOutput (Notice, Notice) p

deployUpdate :: MonadObelisk m => FilePath -> m ()
deployUpdate deployPath = updateThunkToLatest $ deployPath </> "src"

deployMobile :: MonadObelisk m => String -> [String] -> m ()
deployMobile platform mobileArgs = withProjectRoot "." $ \root -> do
  let srcDir = root </> "src"
  exists <- liftIO $ doesDirectoryExist srcDir
  unless exists $ failWith "ob test should be run inside of a deploy directory"
  when (platform == "android") $ do
    let keystorePath = root </> "android_keystore.jks"
    hasKeystore <- liftIO $ doesFileExist keystorePath
    when (not hasKeystore) $ do
      -- TODO log instructions for how to modify the keystore
      putLog Notice $ "Creating keystore: " <> T.pack keystorePath
      createKeystore root $ KeytoolConfig
        { _keytoolConfig_keystore = keystorePath
        , _keytoolConfig_alias = "obelisk"
        , _keytoolConfig_storepass = "obelisk"
        , _keytoolConfig_dname = "CN=mqttserver.ibm.com, OU=ID, O=IBM, L=Hursley, S=Hants, C=GB" -- TODO Read these from config?
        }
    let releaseKey = renderAttrset $ Map.fromList
          [ ("storeFile", Val_Path keystorePath)
          , ("storePassword", Val_Text "obelisk")
          , ("keyAlias", Val_Text "obelisk")
          , ("keyPassword", Val_Text "obelisk")
          ]
    result <- nixCmd $ NixCmd_Build $ def
      & nixBuildConfig_outLink .~ OutLink_None
      & nixCmdConfig_target .~ Target
        { _target_path = Nothing
        , _target_attr = Nothing
        , _target_expr = Just $ "with (import " <> srcDir <> " {}); "  <> platform <> ".frontend.override (drv: { releaseKey = drv.releaseKey // " <> T.unpack releaseKey <> "; })"
        }
    callProcessAndLogOutput (Notice, Error) $ proc (result </> "bin" </> "deploy") mobileArgs

data Val
  = Val_Text Text
  | Val_Path FilePath

renderVal :: Val -> Text
renderVal = \case
  Val_Text x -> "\"" <> x <> "\""
  Val_Path p -> T.pack p

renderAttrset :: Map Text Val -> Text
renderAttrset m = "{ " <> mconcat (map (\(k,v) -> k <> " = " <> renderVal v <> ";") $ Map.toList m) <> " }"

data KeytoolConfig = KeytoolConfig
  { _keytoolConfig_keystore :: FilePath
  , _keytoolConfig_alias :: String
  , _keytoolConfig_storepass :: String
  , _keytoolConfig_dname :: String
  } deriving (Show)

createKeystore :: MonadObelisk m => FilePath -> KeytoolConfig -> m ()
createKeystore root config = do
  let expr = "with (import " <> toImplDir root <> ").reflex-platform.nixpkgs; pkgs.mkShell { buildInputs = [ pkgs.jdk ]; }"
  callProcessAndLogOutput (Notice,Notice) $ (proc "nix-shell" ["-E" , expr, "--run" , keytoolCmd]) { cwd = Just root }
  where
    keytoolCmd = unwords $ "keytool" :
      [ "-genkeypair -noprompt"
      , "-keystore", _keytoolConfig_keystore config
      , "-keyalg RSA -keysize 2048 -validity 10000"
      , "-storetype pkcs12"
      , "-storepass", _keytoolConfig_storepass config
      , "-alias", _keytoolConfig_alias config
      , "-dname ", quote $ _keytoolConfig_dname config
      ]
    quote x = "\"" <> x <> "\""


-- | Simplified deployment configuration mechanism. At one point we may revisit this.
writeDeployConfig :: MonadObelisk m => FilePath -> FilePath -> String -> m ()
writeDeployConfig deployDir fname = liftIO . writeFile (deployDir </> fname)

readDeployConfig :: MonadObelisk m => FilePath -> FilePath -> m String
readDeployConfig deployDir fname = liftIO $ do
  fmap (T.unpack . T.strip) $ T.readFile $ deployDir </> fname

verifyHostKey :: MonadObelisk m => FilePath -> FilePath -> String -> m ()
verifyHostKey knownHostsPath keyPath hostName =
  callProcessAndLogOutput (Notice, Warning) $ proc "ssh" $
    sshArgs knownHostsPath keyPath True <>
      [ "root@" <> hostName
      , "-o", "NumberOfPasswordPrompts=0"
      , "exit"
      ]

sshArgs :: FilePath -> FilePath -> Bool -> [String]
sshArgs knownHostsPath keyPath askHostKeyCheck =
  [ "-o", "UserKnownHostsFile=" <> knownHostsPath
  , "-o", "StrictHostKeyChecking=" <> if askHostKeyCheck then "ask" else "yes"
  , "-i", keyPath
  ]

-- common/route validation
-- TODO: move these to executable-config once the typed-config stuff is done.

data InvalidRoute
  = InvalidRoute_NotHttps URI
  | InvalidRoute_MissingScheme URI
  | InvalidRoute_MissingHost URI
  | InvalidRoute_HasPort URI
  | InvalidRoute_HasPath URI
  deriving Show

instance Exception InvalidRoute where
  displayException = \case
    InvalidRoute_MissingScheme uri -> route uri "must have an URI scheme"
    InvalidRoute_NotHttps uri -> route uri "must be HTTPS"
    InvalidRoute_MissingHost uri -> route uri "must contain a hostname"
    InvalidRoute_HasPort uri -> route uri "cannot specify port"
    InvalidRoute_HasPath uri -> route uri "cannot contain path"
    where
      route uri err = T.unpack $ "Route (" <> URI.render uri <> ") " <> err

-- | Get the hostname from a https route
--
-- Fail if the route is invalid (i.e, no host present or scheme is not https)
getHostFromRoute
  :: MonadObelisk m
  => Bool  -- ^ Ensure https?
  -> String
  -> m String
getHostFromRoute mustBeHttps route = do
  result :: Either InvalidRoute String <- try $ do
    validateCommonRouteAndGetHost mustBeHttps =<< URI.mkURI (T.strip $ T.pack route)
  either (failWith . T.pack . displayException) pure result

validateCommonRouteAndGetHost
  :: (MonadThrow m, MonadObelisk m)
  => Bool -- ^ Ensure https?
  -> URI
  -> m String
validateCommonRouteAndGetHost mustBeHttps uri = do
  case uri ^? uriScheme of
    Just (Just (URI.unRText -> s)) -> case (mustBeHttps, s) of
      (False, _) -> pure ()
      (True, "https") -> pure ()
      _ -> throwM $ InvalidRoute_NotHttps uri
    _ -> throwM $ InvalidRoute_MissingScheme uri
  case uri ^. uriPath of
    [] -> pure ()
    _path -> throwM $ InvalidRoute_HasPath uri
  case uri ^? uriAuthority . _Right . authPort of
    Just (Just _port) -> throwM $ InvalidRoute_HasPort uri
    _ -> pure ()
  case uri ^? uriAuthority . _Right . authHost of
    Nothing -> throwM $ InvalidRoute_MissingHost uri
    Just sslHost -> return $ T.unpack $ URI.unRText sslHost
