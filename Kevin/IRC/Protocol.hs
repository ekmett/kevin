module Kevin.IRC.Protocol (
    cleanup,
    listen,
    errHandlers,
    getAuthInfo
) where

import qualified Data.Text as T
import qualified Data.Text.IO as T
import Kevin.Base
import Kevin.Util.Logger
import Kevin.Util.Token
import Kevin.Util.Entity
import Kevin.IRC.Packet
import qualified Kevin.Damn.Protocol.Send as D
import Kevin.IRC.Protocol.Send
import Control.Applicative ((<$>))
import Control.Arrow
import Control.Monad.State
import Data.Maybe
import Data.List (nubBy)
import Data.Function (on)
import qualified Data.Map as M

type KevinState = StateT Settings IO

cleanup :: KevinIO ()
cleanup = klog Green "cleanup client"

listen :: KevinIO ()
listen = fix (\f -> flip catches errHandlers $ do
    k <- get_
    pkt <- io $ parsePacket <$> readClient k
    respond pkt (command pkt)
    f)

respond :: Packet -> T.Text -> KevinIO ()
respond BadPacket _ = sendNotice "Bad packet, try again."
respond pkt "JOIN" = do
    l <- gets_ (^. loggedIn)
    if l
        then mapM_ D.sendJoin rooms
        else kevin $ joining %= (rooms ++)
    where
        rooms = T.splitOn "," . head . params $ pkt

respond pkt "PART" = mapM_ D.sendPart . T.splitOn "," . head . params $ pkt

respond pkt "PRIVMSG" = do
    let (room:msg:_) = params pkt
    if "\1ACTION" `T.isPrefixOf` msg
        then do
            let newMsg = T.drop 8 $ T.init msg
            D.sendAction room $ entityEncode newMsg
        else D.sendMsg room $ entityEncode msg

respond pkt "MODE" = if length (params pkt) > 1
    then do
        let (toggle,mode) = first (=="+") $ T.splitAt 1 (params pkt !! 1)
        case mode of
            "b" -> if' toggle D.sendBan D.sendUnban (head $ params pkt) (fromMaybe "random unparseable garbage" . unmask . last . params $ pkt)
            "o" -> if' toggle D.sendPromote D.sendDemote (head $ params pkt) (last $ params pkt) Nothing
            _ -> sendRoomNotice (head $ params pkt) $ "Unsupported mode " `T.append` mode
    else do
        uname <- use_ name
        sendChanMode uname (head $ params pkt)

respond pkt "TOPIC" = case params pkt of
	[] -> sendNotice "Malformed packet"
	[room] -> D.sendGet room "topic"
	(room:topic:_) -> D.sendSet room "topic" topic

respond pkt "TITLE" = case params pkt of
	[] -> sendNotice "Malformed packet"
	[room] -> do
		title <- gets_ $  M.lookup room . (^. titles)
		let p = T.concat ["Title for ", room, ": "] in mapM_ (sendRoomNotice room . T.append p) (T.splitOn "\n" $ fromMaybe "" title)
	(room:title) -> D.sendSet room "title" $ T.unwords title

respond pkt "PING" = sendPong (head $ params pkt)

respond pkt "WHOIS" = D.sendWhois . head . params $ pkt

respond pkt "NAMES" = do
    let (room:_) = params pkt
    k <- get_
    sendUserList (k^.name) (nubBy ((==) `on` username) (k^.users.ix room)) room

respond pkt "KICK" = let p = params pkt in D.sendKick (head p) (p !! 1) (if length p > 2 then Just $ last p else Nothing)

respond _ "QUIT" = klogError "client quit" >> undefined

respond pkt "ADMIN" = let (p:ps) = params pkt in D.sendAdmin p $ T.intercalate " " ps

respond pkt "PROMOTE" = case params pkt of
    (room:user:group:_) -> D.sendPromote room user $ Just group
    (room:_) -> sendRoomNotice room "Usage: /promote #room username group"
    _ -> sendNotice "Usage: /promote #room username group"

respond _ str = klogError $ T.unpack str


unmask :: T.Text -> Maybe T.Text
unmask y = case T.split (`elem` "@!") y of
    [s] -> Just s
    xs -> listToMaybe $ filter (not . T.isInfixOf "*") xs

errHandlers :: [Handler KevinIO ()]
errHandlers = [Handler (\(_ :: KevinException) -> klogError "Bad communication from client"),
               Handler (\(e :: IOException) -> klogError $ "client: " ++ show e)]

-- * Authentication-getting function
notice :: Handle -> T.Text -> IO ()
notice h str = klogNow Blue ("client -> " ++ T.unpack asStr) >> T.hPutStr h (asStr `T.append` "\r\n")
    where
        asStr = printf "NOTICE AUTH :%s" [str]

getAuthInfo :: Handle -> Bool -> KevinState ()
getAuthInfo handle = fix (\f authRetry -> do
    pkt <- io $ parsePacket <$> T.hGetLine handle
    io $ klogNow Yellow $ "client <- " ++ T.unpack (readable pkt)
    case command pkt of
        "PASS" -> do
           password .= head (params pkt)
           passed .= True
        "NICK" -> do
           name .= head (params pkt)
           nicked .= True
        "USER" -> usered .= True
        _ -> io $ klogNow Red $ "invalid packet: " ++ show pkt
    if authRetry
        then checkToken handle
        else do
            p <- use passed
            n <- use nicked
            u <- use usered
            if p && n && u
                then welcome handle
                else f False
    )

welcome :: Handle -> KevinState ()
welcome handle = do
    nick <- use name
    mapM_ (\x -> io $ klogNow Blue ("client -> " ++ T.unpack x) >> T.hPutStr handle (x `T.append` "\r\n")) [
        printf ":%s 001 %s :Welcome to dAmnServer %s!%s@chat.deviantart.com" [hostname, nick, nick, nick],
        printf ":%s 002 %s :Your host is chat.deviantart.com, running dAmnServer 0.3" [hostname, nick],
        printf ":%s 003 %s :This server was created Thu Apr 28 1994 at 05:30:00 EDT" [hostname, nick],
        printf ":%s 004 %s chat.deviantart.com dAmnServer0.3 qov i" [hostname, nick],
        printf ":%s 005 %s PREFIX=(qov)~@+" [hostname, nick],
        printf ":%s 375 %s :- chat.deviantart.com Message of the day -" [hostname, nick],
        printf ":%s 372 %s :- deviantART chat on IRC brought to by kevin %s, created" [hostname, nick, VERSION],
        printf ":%s 372 %s :- and maintained by Joel Taylor <http://otter.github.com>" [hostname, nick],
        printf ":%s 376 %s :End of MOTD command" [hostname, nick]]
    checkToken handle
    where
        hostname = "chat.deviantart.com"

checkToken :: Handle -> KevinState ()
checkToken handle = do
    s <- get
    io $ notice handle "Fetching token..."
    tok <- io $ getToken (s^.name) (s^.password)
    case tok of
        Just t -> do
            authtoken .= t
            io $ notice handle "Successfully authenticated."
        Nothing -> do
            io $ notice handle "Bad password, try again. (/quote pass yourpassword)"
            getAuthInfo handle True
