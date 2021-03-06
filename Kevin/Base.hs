module Kevin.Base (
    module Kevin.Types,
    KevinException(..),
    KevinServer(..),
    User(..),

    -- * Modifiers
    addUser,
    removeUser,
    removeUserAll,
    setUsers,
    numUsers,

    addPrivclass,
    setPrivclasses,
    getPcLevel,
    getPc,
    setUserPrivclass,
    changePrivclassName,

    removeRoom,

    setTitle,

    -- * Exports
    module K,

    -- * Working with KevinState
    io,
    runPrinter,

    if',

    printf
) where

import Kevin.Util.Logger
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as T (hGetLine, hPutStr)
import qualified Data.Text.Encoding as T
import Data.List (intercalate, findIndices)
import Data.Maybe
import System.IO as K
import System.IO.Error
import Control.Exception as K (IOException)
import Network as K
import Control.Applicative ((<$>))
import Control.Monad.Reader as K
import Control.Concurrent as K (forkIO)
import Control.Concurrent.Chan as K
import Control.Concurrent.STM.TVar as K
import Control.Exception
import Control.Lens as K
import Control.Monad.CatchIO as K
import Kevin.Settings as K
import qualified Data.Map as M
import Data.Typeable
import Kevin.Types

if' :: Bool -> a -> a -> a
if' x y z = if x then y else z

mapWhen :: (a -> Bool) -> (a -> a) -> [a] -> [a]
mapWhen f g = map (\x -> if f x then g x else x)

runPrinter :: Chan T.Text -> Handle -> IO ()
runPrinter ch h = void $ forkIO $ forever $ readChan ch >>= T.hPutStr h . T.encodeUtf8

io :: MonadIO m => IO a -> m a
io = liftIO

class KevinServer a where
    readClient, readServer :: a -> IO T.Text
    writeServer :: a -> T.Text -> IO ()
    writeClient :: a -> T.Text -> IO ()
    closeClient, closeServer :: a -> IO ()

data KevinException = ParseFailure
    deriving (Show, Typeable)

instance Exception KevinException

-- actions

padLines :: Int -> T.Text -> String
padLines len b = let (first:rest) = lines $ T.unpack b in (++) (first ++ "\n") . intercalate "\n" . map (replicate len ' ' ++) $ rest

hGetCharTimeout :: Handle -> Int -> IO Char
hGetCharTimeout h t = do
    hSetBuffering h NoBuffering
    ready <- hWaitForInput h t
    if ready
        then do
            c <- hGetChar h
            return c
        else throwIO $ mkIOError eofErrorType "read timeout" (Just h) Nothing

hGetSep :: Char -> Handle -> IO String
hGetSep sep h = fix (\f -> hGetCharTimeout h 90000 >>= \ch -> if ch == sep then return "" else (ch:) <$> f)

instance KevinServer Kevin where
    readClient k = do
        line <- T.decodeUtf8 <$> T.hGetLine (irc k)
        klog_ (logger k) Yellow $ "client <- " ++ padLines 10 line
        return $ T.init line
    readServer k = do
        line <- T.pack <$> hGetSep '\NUL' (damn k)
        klog_ (logger k) Cyan $ "server <- " ++ padLines 10 line
        return line

    writeClient k pkt = do
        klog_ (logger k) Blue $ "client -> " ++ padLines 10 pkt
        writeChan (iChan k) pkt
    writeServer k pkt = do
        klog_ (logger k) Magenta $ "server -> " ++ padLines 10 pkt
        writeChan (dChan k) pkt

    closeClient = hClose . irc
    closeServer = hClose . damn

-- Kevin modifiers
removeRoom :: Chatroom -> Kevin -> Kevin
removeRoom c k = k & privclasses.at c .~ Nothing
                   & users.at c .~ Nothing

-- removeRoom c k = k & privclasses.contains c %~ False
--                    & users.contains c %~ False

addUser :: Chatroom -> User -> UserStore -> UserStore
addUser = (. return) . M.insertWith (++)

numUsers :: Chatroom -> T.Text -> UserStore -> Int
numUsers room us st = case M.lookup room st of
    Just usrs -> length $ findIndices (\u -> us == username u) usrs
    Nothing -> 0

removeUser :: Chatroom -> T.Text -> UserStore -> UserStore
removeUser room us = M.adjust (removeOne' (\x -> username x == us)) room

removeUserAll :: Chatroom -> T.Text -> UserStore -> UserStore
removeUserAll room us = M.adjust (filter (\x -> username x /= us)) room

removeOne' :: (User -> Bool) -> [User] -> [User]
removeOne' _ [] = []
removeOne' f (x:xs) = if f x then xs else x:removeOne' f xs

setUsers :: Chatroom -> [User] -> UserStore -> UserStore
setUsers = M.insert

addPrivclass :: Chatroom -> Privclass -> PrivclassStore -> PrivclassStore
addPrivclass room (p,i) = M.insertWith M.union room (M.singleton p i)

setPrivclasses :: Chatroom -> [Privclass] -> PrivclassStore -> PrivclassStore
setPrivclasses room ps = M.insert room (M.fromList ps)

getPc :: Chatroom -> T.Text -> UserStore -> Maybe T.Text
getPc room user st = case M.lookup room st of
    Just qs -> privclass <$> listToMaybe (filter (\u -> username u == user) qs)
    Nothing -> Nothing

getPcLevel :: Chatroom -> T.Text -> PrivclassStore -> Int
getPcLevel room pcname store = fromMaybe 0 $ M.lookup room store >>= M.lookup pcname

setUserPrivclass :: Chatroom -> T.Text -> T.Text -> Kevin -> Kevin
setUserPrivclass room user pc k = (users %~ M.adjust (mapWhen ((user ==) . username) (\u -> u {privclass = pc, privclassLevel = pclevel})) room) k
    where
        pclevel = getPcLevel room pc $ k ^. privclasses

changePrivclassName :: Chatroom -> T.Text -> T.Text -> UserStore -> UserStore
changePrivclassName room old new = M.adjust (mapWhen ((old ==) . privclass) (\u -> u {privclass = new})) room

setTitle :: Chatroom -> Title -> TitleStore -> TitleStore
setTitle = M.insert
