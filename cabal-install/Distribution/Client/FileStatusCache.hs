-- | A cache which tracks a value whose validity depends upon
-- the state of various files in the filesystem.

{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving, BangPatterns #-}

module Distribution.Client.FileStatusCache (
  
  -- * Declaring files to monitor
  MonitorFilePath(..),
  FilePathGlob(..),
  monitorFileSearchPath,
  monitorFileHashedSearchPath,

  -- * Creating and checking sets of monitored files
  FileMonitorName(..),
  Changed(..),
  checkFileMonitorChanged,
  updateFileMonitor,

  matchFileGlob,
  --TODO: remove:
--  checkValueChanged,
--  updateValueChangeCache,
  ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Lazy as BS
import           Data.Binary
import qualified Data.Binary as Binary
import           Data.Traversable (traverse)
import qualified Data.Hashable as Hashable
import           Data.List (sort)
import           Data.Time (UTCTime(..), Day(..))

import           Control.Monad
import           Control.Applicative
import           Control.Monad.IO.Class
import           Control.Monad.Trans.State (StateT)
import qualified Control.Monad.Trans.State as State
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Class
import           Control.Exception

import           Distribution.Text
import           Distribution.Compat.ReadP ((<++))
import qualified Distribution.Compat.ReadP as ReadP
import qualified Text.PrettyPrint as Disp

import           Distribution.Client.Glob
import           Distribution.Client.Utils (mergeBy, MergeResult(..))

import           System.FilePath
import           System.Directory
import           System.IO
import           System.IO.Error
import           GHC.Generics (Generic)


------------------------------------------------------------------------------
-- Types for specifying files to monitor
--


-- | A description of a file (or set of files) to monitor for changes.
--
-- All file paths here are relative to a common directory (e.g. project root).
--
data MonitorFilePath =

     -- | Monitor a single file for changes, based on its modification time.
     -- The monitored file is considered to have changed if it no longer
     -- exists or if its modification time has changed.
     --
     MonitorFile !FilePath

     -- | Monitor a single file for changes, based on its modification time
     -- and content hash. The monitored file is considered to have changed if
     -- it no longer exists or if its modification time and content hash have
     -- changed.
     --
   | MonitorFileHashed !FilePath

     -- | Monitor a single non-existant file for changes. The monitored file
     -- is considered to have changed if it exists.
     --
   | MonitorNonExistantFile !FilePath

     -- | Monitor a set of files identified by a file glob. The monitored glob
     -- is considered to have changed if the set of files matching the glob
     -- changes (i.e. creations or deletions), or if the modification time and
     -- content hash of any matching file has changed.
     --
   | MonitorFileGlob !FilePathGlob

  deriving (Show, Generic)

instance Binary MonitorFilePath

-- | A file path specified by globbing
--
data FilePathGlob
   = GlobDir  !Glob !FilePathGlob
   | GlobFile !Glob
  deriving (Eq, Show, Generic)

instance Binary FilePathGlob


monitorFileSearchPath :: [FilePath] -> FilePath -> [MonitorFilePath]
monitorFileSearchPath notFoundAtPaths foundAtPath =
    MonitorFile foundAtPath
  : map MonitorNonExistantFile notFoundAtPaths

monitorFileHashedSearchPath :: [FilePath] -> FilePath -> [MonitorFilePath]
monitorFileHashedSearchPath notFoundAtPaths foundAtPath =
    MonitorFileHashed foundAtPath
  : map MonitorNonExistantFile notFoundAtPaths

-- | A file used to store the state of a file monitor.
--
-- It is typed to ensure it's used at consistent types.
--
newtype FileMonitorName a b = FileMonitorName FilePath
  deriving Show

------------------------------------------------------------------------------
-- Implementation types, files status
--

data MonitorStateFileSet
   = MonitorStateFileSet !(Map FilePath MonitorStateFile)
                         ![FileGlobMonitorState]
  deriving Show

--instance Monoid MonitorStateFileSet where
--  mempty = MonitorStateFileSet Map.empty []
--  MonitorStateFileSet a b `mappend` MonitorStateFileSet x y =
--    MonitorStateFileSet (a<>x) (b<>y)

type Hash = Int
type ModTime = UTCTime

-- | The state necessary to determine whether monitored files have changed.
--
-- This covers all the cases of 'MonitorFilePath' except for globs which is
-- covered separately by 'FileGlobMonitorState'.
--
data MonitorStateFile
   = MonitorStateFile       !ModTime         -- ^ cached file mtime
   | MonitorStateFileHashed !ModTime !Hash   -- ^ cached file mtime and content hash
   | MonitorStateFileNonExistant

     -- | These two are to deal with the situation where we've been asked
     -- to monitor a file that's expected to exist, but when we come to
     -- check it's status, it no longer exists.
   | MonitorStateFileChanged
   | MonitorStateFileHashChanged
  deriving (Show, Generic)

instance Binary MonitorStateFile

-- | The state necessary to determine whether the files matched by a globbing
-- match have changed.
--
data FileGlobMonitorState
   = MonitorStateGlobDirs  !Glob !FilePathGlob
                           !ModTime
                           ![(FilePath, FileGlobMonitorState)] -- invariant: sorted

   | MonitorStateGlobFiles !Glob
                           !ModTime
                           ![(FilePath, ModTime, Hash)] -- invariant: sorted
  deriving (Show, Generic)

instance Binary FileGlobMonitorState

-- We can build a 'MonitorStateFileSet' from a set of 'MonitorFilePath' by
-- inspecting the state of the file system, and we can go in the reverse
-- direction by just forgetting the extra info.
--
reconstructMonitorFilePaths :: MonitorStateFileSet -> [MonitorFilePath]
reconstructMonitorFilePaths (MonitorStateFileSet singlePaths globPaths) =
    Map.foldrWithKey (\k x r -> getSinglePath k x : r)
                     (map getGlobPath globPaths)
                     singlePaths
  where
    getSinglePath filepath monitorState =
      case monitorState of
        MonitorStateFile{}          -> MonitorFile            filepath
        MonitorStateFileHashed{}    -> MonitorFileHashed      filepath
        MonitorStateFileNonExistant -> MonitorNonExistantFile filepath
        MonitorStateFileChanged     -> MonitorFile            filepath
        MonitorStateFileHashChanged -> MonitorFileHashed      filepath

    getGlobPath (MonitorStateGlobDirs  glob globs _ _) =
      MonitorFileGlob (GlobDir  glob globs)
    getGlobPath (MonitorStateGlobFiles glob       _ _) =
      MonitorFileGlob (GlobFile glob)

------------------------------------------------------------------------------
-- Checking the status of monitored files
--

data Changed b = Changed | Unchanged b
  deriving Show


checkFileMonitorChanged
  :: (Eq a, Binary a, Binary b)
  => FileMonitorName a b  -- ^ cache file path
  -> FilePath       -- ^ root directory
  -> a              -- ^ key value
  -> IO (Changed (b, [MonitorFilePath])) -- ^ did the key or any paths change?
checkFileMonitorChanged (FileMonitorName monitorStateFile) root currentKey =

    -- Consider it a change if the cache file does not exist,
    -- or we cannot decode it.
    handleDoesNotExist Changed $
          Binary.decodeFileOrFail monitorStateFile
      >>= either (\_ -> return Changed)
                 checkStatusCache

  where
    -- It's also a change if the guard value has changed
    checkStatusCache (_, cachedKey, _)
      | currentKey /= cachedKey
      = do print "checkFileMonitorChanged: key value changed"
           return Changed

    checkStatusCache (cachedFileStatus, cachedKey, cachedResult) = do

      -- Now we have to go probe the file system.
      res <- probeFileSystem root cachedFileStatus
      case res of
        -- Some monitored file has changed
        Nothing -> do
          print "checkFileMonitorChanged: files changed"
          return Changed
        
        -- No monitored file has changed
        Just (cachedFileStatus', cacheStatus) -> do

          -- But we might still want to update the cache
          whenCacheChanged cacheStatus $
            rewriteCache cachedFileStatus' cachedKey cachedResult

          let monitorFiles = reconstructMonitorFilePaths cachedFileStatus'
          return (Unchanged (cachedResult, monitorFiles))

    rewriteCache cachedFileStatus' cachedKey cachedResult = 
      Binary.encodeFile monitorStateFile
                        (cachedFileStatus', cachedKey, cachedResult)

-- | Probe the file system to see if any of the monitored files have changed.
--
-- It returns Nothing if any file changed, or returns a possibly updated
-- file 'MonitorStateFileSet' plus an indicator of whether it actually changed.
--
-- We may need to update the cache since there may be changes in the filesystem
-- state which don't change any of our affected files.
--
-- Consider the glob @{proj1,proj2}/*.cabal@. Say we first run and find a
-- @proj1@ directory containing @proj1.cabal@ yet no @proj2@. If we later run
-- and find @proj2@ was created, yet contains no files matching @*.cabal@ then
-- we want to update the cache despite no changes in our relevant file set.
-- Specifically, we should add an mtime for this directory so we can avoid
-- re-traversing the directory in future runs.
--
probeFileSystem :: FilePath -> MonitorStateFileSet
                -> IO (Maybe (MonitorStateFileSet, CacheChanged))
probeFileSystem root (MonitorStateFileSet singlePaths globPaths) =
  runChangedM $
    MonitorStateFileSet
      <$> Map.traverseWithKey (probeFileStatus root)     singlePaths
      <*> traverse            (probeGlobStatus root ".") globPaths

-----------------------------------------------
-- Monad for checking for file system changes
--
-- We need to be able to bail out if we detect a change (using MaybeT),
-- but if there's no change we need to be able to rebuild the monitor
-- state. And we want to optimise that rebuilding by keeping track if
-- anything actually changed (using StateT), so that in the typical case
-- we can avoid rewriting the state file.

newtype ChangedM a = ChangedM (StateT CacheChanged (MaybeT IO) a)
  deriving (Functor, Applicative, Monad, MonadIO)

runChangedM :: ChangedM a -> IO (Maybe (a, CacheChanged))
runChangedM (ChangedM action) =
  runMaybeT $ State.runStateT action CacheUnchanged

somethingChanged :: ChangedM a
somethingChanged = ChangedM $ lift $ MaybeT $ return Nothing

cacheChanged :: ChangedM ()
cacheChanged = ChangedM $ State.put CacheChanged

data CacheChanged = CacheChanged | CacheUnchanged

whenCacheChanged :: Monad m => CacheChanged -> m () -> m ()
whenCacheChanged CacheChanged action = action
whenCacheChanged CacheUnchanged _    = return ()

----------------------

-- | Probe the file system to see if a single monitored file has changed.
--
probeFileStatus :: FilePath -> FilePath -> MonitorStateFile
                -> ChangedM MonitorStateFile
probeFileStatus root file cached = do
    case cached of
      MonitorStateFile       mtime      -> probeFileModificationTime
                                             root file mtime
      MonitorStateFileHashed mtime hash -> probeFileModificationTimeAndHash
                                             root file mtime hash
      MonitorStateFileNonExistant       -> probeFileNonExistance root file
      MonitorStateFileChanged           -> somethingChanged
      MonitorStateFileHashChanged       -> somethingChanged

    return cached


-- | Probe the file system to see if a monitored file glob has changed.
--
probeGlobStatus :: FilePath      -- ^ root path
                -> FilePath      -- ^ path of the directory we are looking in relative to @root@
                -> FileGlobMonitorState
                -> ChangedM FileGlobMonitorState
probeGlobStatus root dirName (MonitorStateGlobDirs glob globPath mtime children) = do
    change <- liftIO $ checkDirectoryModificationTime (root </> dirName) mtime
    case change of
      Nothing -> do
        children' <- sequence
                       [ do cgp' <- probeGlobStatus root (dirName </> fname) cgp
                            return (fname, cgp')
                       | (fname, cgp) <- children ]
        return $! MonitorStateGlobDirs glob globPath mtime children'

      Just mtime' -> do
        -- directory modification time changed:
        -- a matching subdir may have been added or deleted
        matches <- filterM (\entry -> let subdir = root </> dirName </> entry
                                       in liftIO $ doesDirectoryExist subdir)
                 . filter (globMatches glob)
               =<< liftIO (getDirectoryContents (root </> dirName))

        children' <- mapM probeMergeResult $
                          mergeBy (\(path1,_) path2 -> compare path1 path2)
                                  children
                                  (sort matches)
        return $! MonitorStateGlobDirs glob globPath mtime' children'
        -- Note that just because the directory has changed, we don't force
        -- a cache rewite with 'cacheChanged' since that has some cost, and
        -- all we're saving is scanning the directory. But we do rebuild the
        -- cache with the new mtime', so that if the cache is rewritten for
        -- some other reason, we'll take advantage of that.
    

  where
    probeMergeResult :: MergeResult (FilePath, FileGlobMonitorState) FilePath
                     -> ChangedM (FilePath, FileGlobMonitorState)

    -- Only in cached (directory deleted)
    probeMergeResult (OnlyInLeft (path, cgp))
      | not (hasMatchingFiles cgp) = return (path, cgp)
        -- Strictly speaking we should be returning 'CacheChanged' above
        -- as we should prune the now-missing 'FileGlobMonitorState'. However
        -- we currently just leave these now-redundant entries in the
        -- cache as they cost no IO and keeping them allows us to avoid
        -- rewriting the cache.
      | otherwise = somethingChanged

    -- Only in current filesystem state (directory added)
    probeMergeResult (OnlyInRight path) = do
      cgp <- liftIO $ buildFileGlobMonitorState root (dirName </> path) globPath
      if hasMatchingFiles cgp
        then somethingChanged
        else cacheChanged >> return (path, cgp)

    -- Found in path
    probeMergeResult (InBoth (path, cgp) _) = do
      cgp' <- probeGlobStatus root (dirName </> path) cgp
      return (path, cgp')

    -- | Does a 'FileGlobMonitorState' have any relevant files within it?
    hasMatchingFiles :: FileGlobMonitorState -> Bool
    hasMatchingFiles (MonitorStateGlobFiles _ _   entries) = not (null entries)
    hasMatchingFiles (MonitorStateGlobDirs  _ _ _ entries) =
      any (hasMatchingFiles . snd) entries


probeGlobStatus root dirName (MonitorStateGlobFiles glob mtime children) = do
    change <- liftIO $ checkDirectoryModificationTime (root </> dirName) mtime
    mtime' <- case change of
      Nothing     -> return mtime
      Just mtime' -> do
        -- directory modification time changed:
        -- a matching file may have been added or deleted
        matches <- filterM (\entry -> let file = root </> dirName </> entry
                                       in liftIO $ doesFileExist file)
                 . filter (globMatches glob)
               =<< liftIO (getDirectoryContents (root </> dirName))

        let mergeRes = mergeBy (\(path1,_,_) path2 -> compare path1 path2)
                         children
                         (sort matches)
        unless (all isInBoth mergeRes) somethingChanged
        return mtime'

    -- Check that none of the children have changed
    forM_ children $ \(file, fmtime, fhash) ->
        probeFileModificationTimeAndHash root (dirName </> file) fmtime fhash

    return (MonitorStateGlobFiles glob mtime' children)
    -- Again, we don't force a cache rewite with 'cacheChanged', but we do use
    -- the new mtime' if any.
  where
    isInBoth :: MergeResult a b -> Bool
    isInBoth (InBoth _ _) = True
    isInBoth _            = False

------------------------------------------------------------------------------

updateFileMonitor
  :: (Binary a, Binary b)
  => FileMonitorName a b -- ^ cache file path
  -> FilePath            -- ^ root directory
  -> [MonitorFilePath]   -- ^ patterns of interest relative to root
  -> a                   -- ^ a cached key value
  -> b                   -- ^ a cached value dependent upon the key and on the
                         --   paths identified by the given patterns
  -> IO ()
updateFileMonitor (FileMonitorName cacheFile) root
                  monitorFiles cachedKey cachedResult = do
    fsc <- buildMonitorStateFileSet root monitorFiles
    Binary.encodeFile cacheFile (fsc, cachedKey, cachedResult)

buildMonitorStateFileSet :: FilePath          -- ^ root directory
                         -> [MonitorFilePath] -- ^ patterns of interest relative to root
                         -> IO MonitorStateFileSet
buildMonitorStateFileSet root =
    go Map.empty []
  where
    go :: Map FilePath MonitorStateFile -> [FileGlobMonitorState]
       -> [MonitorFilePath] -> IO MonitorStateFileSet
    go !singlePaths !globPaths [] =
      return (MonitorStateFileSet singlePaths globPaths)

    go !singlePaths !globPaths (MonitorFile path : monitors) = do
      let file = root </> path
      monitorState <- handleDoesNotExist MonitorStateFileChanged $
                        MonitorStateFile <$> getModificationTime file
      let singlePaths' = Map.insert path monitorState singlePaths
      go singlePaths' globPaths monitors

    go !singlePaths !globPaths (MonitorFileHashed path : monitors) = do
      let file = root </> path
      monitorState <- handleDoesNotExist MonitorStateFileHashChanged $
                        MonitorStateFileHashed
                          <$> getModificationTime file
                          <*> readFileHash file
      let singlePaths' = Map.insert path monitorState singlePaths
      go singlePaths' globPaths monitors

    go !singlePaths !globPaths (MonitorNonExistantFile path : monitors) = do
      let singlePaths' = Map.insert path MonitorStateFileNonExistant singlePaths
      go singlePaths' globPaths monitors

    go !singlePaths !globPaths (MonitorFileGlob globPath : monitors) = do
      monitorState <- buildFileGlobMonitorState root "." globPath
      go singlePaths (monitorState : globPaths) monitors


buildFileGlobMonitorState :: FilePath     -- ^ the root directory
                          -> FilePath     -- ^ directory we are examining relative to the root
                          -> FilePathGlob -- ^ the matching glob
                          -> IO FileGlobMonitorState
buildFileGlobMonitorState root dir globPath = do
    dirEntries <- getDirectoryContents (root </> dir)
    dirMTime   <- getModificationTime (root </> dir)
    case globPath of
      GlobDir glob globPath' -> do
        subdirs <- filterM (\subdir -> doesDirectoryExist (root </> dir </> subdir))
                 $ filter (globMatches glob) dirEntries
        subdirStates <-
          forM subdirs $ \subdir -> do
            cgp <- buildFileGlobMonitorState root (dir </> subdir) globPath'
            return (subdir, cgp)
        return $! MonitorStateGlobDirs glob globPath' dirMTime subdirStates

      GlobFile glob -> do
        files <- filterM (\fname -> doesFileExist (root </> dir </> fname))
               $ filter (globMatches glob) dirEntries
        filesStates <-
          forM (sort files) $ \file -> do
            let path = root </> dir </> file
            mtime <- getModificationTime path
            hash  <- readFileHash path
            return (file, mtime, hash)
        return $! MonitorStateGlobFiles glob dirMTime filesStates

matchFileGlob :: FilePath -> FilePathGlob -> IO [FilePath]
matchFileGlob root glob0 = go glob0 ""
  where
    go (GlobFile glob) dir = do
      entries <- getDirectoryContents (root </> dir)
      let files = filter (globMatches glob) entries
      return (map (dir </>) files)

    go (GlobDir glob globPath) dir = do
      entries <- getDirectoryContents (root </> dir)
      subdirs <- filterM (\subdir -> doesDirectoryExist (root </> dir </> subdir))
               $ filter (globMatches glob) entries
      concat <$> mapM (\subdir -> go globPath (dir </> subdir)) subdirs
 

------------------------------------------------------------------------------
-- Utils
-- 

probeFileModificationTime :: FilePath -> FilePath -> ModTime -> ChangedM ()
probeFileModificationTime root file mtime = do
    unchanged <- liftIO $ checkModificationTimeUnchanged root file mtime
    unless unchanged somethingChanged

probeFileModificationTimeAndHash :: FilePath -> FilePath -> ModTime -> Hash
                                 -> ChangedM ()
probeFileModificationTimeAndHash root file mtime hash = do
    unchanged <- liftIO $
      checkFileModificationTimeAndHashUnchanged root file mtime hash
    unless unchanged somethingChanged

probeFileNonExistance :: FilePath -> FilePath -> ChangedM ()
probeFileNonExistance root file = do
    exists <- liftIO $ doesFileExist (root </> file)
    when exists somethingChanged

-- | File name relative to @root@
checkModificationTimeUnchanged :: FilePath -> FilePath
                               -> ModTime -> IO Bool
checkModificationTimeUnchanged root file mtime =
  handleDoesNotExist False $ do
    mtime' <- getModificationTime (root </> file)

    --TODO: debug only:
    when (mtime /= mtime') $
      print ("file mtime changed", file)

    return (mtime == mtime')

-- | File name relative to @root@
checkFileModificationTimeAndHashUnchanged :: FilePath -> FilePath
                                          -> ModTime -> Hash -> IO Bool
checkFileModificationTimeAndHashUnchanged root file mtime chash =
  handleDoesNotExist False $ do
    mtime' <- getModificationTime (root </> file)
    
    if mtime == mtime'
      then return True
      else do
        chash' <- readFileHash (root </> file)

        --TODO: debug only:
        if chash /= chash'
          then print ("file hash changed", file)
          else print ("file mtime changed, but hash unchanged", file)

        return (chash == chash')

readFileHash :: FilePath -> IO Hash
readFileHash file =
    withBinaryFile file ReadMode $ \hnd ->
      evaluate . Hashable.hash =<< BS.hGetContents hnd

checkDirectoryModificationTime :: FilePath -> ModTime -> IO (Maybe ModTime)
checkDirectoryModificationTime dir mtime =
  handleDoesNotExist Nothing $ do
    mtime' <- getModificationTime dir
    if mtime == mtime'
      then return Nothing
      else return (Just mtime')

handleDoesNotExist :: a -> IO a -> IO a
handleDoesNotExist e =
    handleJust
      (\ioe -> if isDoesNotExistError ioe then Just ioe else Nothing)
      (\_ -> return e)

------------------------------------------------------------------------------
-- Instances
-- 

instance Text FilePathGlob where
  disp (GlobDir  glob pathglob) = disp glob Disp.<> Disp.char '/'
                                            Disp.<> disp pathglob
  disp (GlobFile glob)          = disp glob

  parse = parse >>= \glob ->
            (do _ <- ReadP.char '/'
                globs <- parse
                return (GlobDir glob globs))
        <++ return (GlobFile glob)

instance Binary UTCTime where
  put (UTCTime (ModifiedJulianDay day) tod) = do
    put day
    put (toRational tod)
  get = do
    day  <- get
    tod <- get
    return $! UTCTime (ModifiedJulianDay day)
                      (fromRational tod)

instance Binary MonitorStateFileSet where
  put (MonitorStateFileSet singlePaths globPaths) = do
    put (1 :: Int) -- version
    put singlePaths
    put globPaths
  get = do
    ver <- get
    if ver == (1 :: Int)
      then do singlePaths <- get
              globPaths   <- get
              return $! MonitorStateFileSet singlePaths globPaths
      else fail "MonitorStateFileSet: wrong version"

---------------------------------------------------------------------
-- Deprecated
--

{-
checkValueChanged :: (Binary a, Eq a, Binary b)
                  => FilePath -> a -> IO (Changed b)
checkValueChanged cacheFile currentValue =
    handleDoesNotExist Changed $ do   -- cache file didn't exist
      res <- Binary.decodeFileOrFail cacheFile
      case res of
        Right (cachedValue, cachedPayload)
          | currentValue == cachedValue
                       -> return (Unchanged cachedPayload)
          | otherwise  -> return Changed -- value changed
        Left _         -> return Changed -- decode error


updateValueChangeCache :: (Binary a, Binary b) => FilePath -> a -> b -> IO ()
updateValueChangeCache path key payload =
    Binary.encodeFile path (key, payload)
-}
