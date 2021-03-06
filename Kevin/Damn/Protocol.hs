module Kevin.Damn.Protocol (
    initialize,
    cleanup,
    listen,
    errHandlers
) where

import Kevin.Base
import Kevin.Util.Logger
import Kevin.Util.Entity
import Kevin.Util.Tablump
import Kevin.Damn.Packet
import qualified Data.Text as T
import Data.Maybe (fromJust, fromMaybe)
import Data.List (nub, delete, sortBy)
import Data.Ord (comparing)
import Kevin.Damn.Protocol.Send
import qualified Kevin.IRC.Protocol.Send as I
import Control.Applicative ((<$>))
import Control.Arrow ((&&&))
import Data.Time.Clock.POSIX (getPOSIXTime)

initialize :: KevinIO ()
initialize = sendHandshake

cleanup :: KevinIO ()
cleanup = klog Blue "cleanup server"

listen :: KevinIO ()
listen = fix (\f -> flip catches errHandlers $ do
    k <- get_
    pkt <- io $ parsePacket <$> readServer k
    respond pkt (command pkt)
    f)

-- main responder
respond :: Packet -> T.Text -> KevinIO ()
respond _ "dAmnServer" = do
    s <- use_ settings
    sendLogin (s^.name) (s^.authtoken)

respond pkt "login" = if okay pkt
    then do
        j <- kevin $ do
           loggedIn .= True
           use joining
        mapM_ sendJoin j
    else I.sendNotice $ "Login failed: " `T.append` getArg "e" pkt

respond pkt "join" = do
    roomname <- deformatRoom . fromJust . parameter $ pkt
    if okay pkt
        then do
            kevin $ joining %= (roomname:)
            uname <- use_ name
            I.sendJoin uname roomname
        else I.sendNotice $ T.concat ["Couldn't join ", roomname, ": ", getArg "e" pkt]

respond pkt "part" = do
    roomname <- deformatRoom . fromJust . parameter $ pkt
    if okay pkt
        then do
            uname <- use_ name
            modify_ $ removeRoom roomname
            I.sendPart uname roomname Nothing
        else I.sendNotice $ T.concat ["Couldn't part ", roomname, ": ", getArg "e" pkt]

respond pkt "property" = deformatRoom (fromJust $ parameter pkt) >>= \roomname ->
    case getArg "p" pkt of
    "privclasses" -> do
        let pcs = parsePrivclasses . fromJust . body $ pkt
        modify_ $ privclasses %~ setPrivclasses roomname pcs

    "topic" -> do
        uname <- use_ name
        I.sendTopic uname roomname (getArg "by" pkt) (T.replace "\n" " - " . entityDecode . tablumpDecode . fromJust . body $ pkt) (getArg "ts" pkt)

    "title" -> modify_ $ titles %~ setTitle roomname (T.replace "\n" " - " . entityDecode . tablumpDecode . fromJust . body $ pkt)

    "members" -> do
        k <- get_
        let members = map (mkUser roomname (k^.privclasses) . parsePacket) . init . splitOn "\n\n" . fromJust $ body pkt
            pc = privclass . head . filter (\x -> username x == k^.name) $ members
            n = nub members
        modify_ $ users %~ setUsers roomname members
        when (roomname `elem` k^.joining) $ do
            I.sendUserList (k^.name) n roomname
            I.sendWhoList (k^.name) n roomname
            I.sendSetUserMode (k^.name) roomname $ getPcLevel roomname pc (k^.privclasses)
            modify_ $ joining %~ delete roomname

    "info" -> do
        us <- use_ name
        curtime <- io $ floor <$> getPOSIXTime
        let fixedPacket = parsePacket . T.init . T.replace "\n\nusericon" "\nusericon" . readable $ pkt
            uname = T.drop 6 . fromJust . parameter $ pkt
            rn = getArg "realname" fixedPacket
            conns = map (\x -> (read (T.unpack $ getArg "online" x) :: Int, read (T.unpack $ getArg "idle" x) :: Int, map (T.drop 8) . filter (not . T.null) . T.splitOn "\n\n" . fromJust . body $ x)) . fromJust $ (map (parsePacket . T.append "conn") . tail . T.splitOn "conn") <$> body fixedPacket
            allRooms = nub $ conns >>= (\(_,_,c) -> c)
            (onlinespan,idle) = head . sortBy (comparing fst) . map (\(a,b,_) -> (a,b)) $ conns
            signon = curtime - onlinespan
        I.sendWhoisReply us uname (entityDecode rn) allRooms idle signon

    q -> klogError $ "Unrecognized property " ++ T.unpack q

respond spk "recv" = deformatRoom (fromJust $ parameter spk) >>= \roomname ->
    case command pkt of
    "join" -> do
        let usname = fromJust $ parameter pkt
        (pcs,countUser) <- gets_ $ view privclasses &&& numUsers roomname usname . view users
        let us = mkUser roomname pcs modifiedPkt
        modify_ $ users %~ addUser roomname us
        if countUser == 0
            then do
                I.sendJoin usname roomname
                I.sendSetUserMode usname roomname $ getPcLevel roomname (getArg "pc" modifiedPkt) pcs
            else I.sendNoticeClone (username us) (succ countUser) roomname

    "part" -> do
        let uname = fromJust $ parameter pkt
        modify_ $ users %~ removeUser roomname uname
        countUser <- gets_ $ numUsers roomname uname . view users
        if countUser < 1
            then I.sendPart uname roomname $ case getArg "r" pkt of { "" -> Nothing; x -> Just x }
            else I.sendNoticeUnclone uname countUser roomname

    "msg" -> do
        let uname = arg "from"
            msg   = fromJust (body pkt)
        un <- use_ name
        unless (un == uname) $ I.sendChanMsg uname roomname (entityDecode $ tablumpDecode msg)

    "action" -> do
        let uname = arg "from"
            msg   = fromJust (body pkt)
        un <- use_ name
        unless (un == uname) $ I.sendChanAction uname roomname (entityDecode $ tablumpDecode msg)

    "privchg" -> do
        (pcs,us) <- gets_ $ view privclasses &&& view users
        let user = fromJust $ parameter pkt
            by = arg "by"
            oldPc = getPc roomname user us
            newPc = arg "pc"
            oldPcLevel = fmap (\p -> getPcLevel roomname p pcs) oldPc
            newPcLevel = getPcLevel roomname newPc pcs
        modify_ $ setUserPrivclass roomname user newPc
        I.sendRoomNotice roomname $ T.concat [user, " has been moved", maybe "" (T.append " from ") oldPc, " to ", newPc, " by ", by]
        I.sendChangeUserMode user roomname (fromMaybe 0 oldPcLevel) newPcLevel

    "kicked" -> do
        let uname = fromJust $ parameter pkt
        modify_ $ users %~ removeUserAll roomname uname
        I.sendKick uname (arg "by") roomname $ case body pkt of {Just "" -> Nothing; x -> x}

    "admin" -> case fromJust $ parameter pkt of
        "create" -> I.sendRoomNotice roomname $ T.concat ["Privclass ", arg "name", " created by ", arg "by", " with: ", arg "privs"]
        "update" -> I.sendRoomNotice roomname $ T.concat ["Privclass ", arg "name", " updated by ", arg "by", " with: ", arg "privs"]
        "rename" -> I.sendRoomNotice roomname $ T.concat ["Privclass ", arg "prev", " renamed to ", arg "name", " by ", arg "by"]
        "move"   -> I.sendRoomNotice roomname $ T.concat [arg "n", " users in privclass ", arg "prev", " moved to ", arg "name", " by ", arg "by"]
        "remove" -> I.sendRoomNotice roomname $ T.concat ["Privclass", arg "name", " removed by ", arg "by"]
        "show"   -> mapM_ (I.sendRoomNotice roomname) . T.splitOn "\n" . fromJust . body $ pkt
        "privclass" -> I.sendRoomNotice roomname $ "Admin error: " `T.append` arg "e"
        q -> klogError $ "Unknown admin packet type " ++ show q

    x -> klogError $ "Unknown packet type " ++ show x

    where
        pkt = fromJust $ subPacket spk
        modifiedPkt = parsePacket (T.replace "\n\npc" "\npc" (fromJust $ body spk))
        arg = flip getArg pkt

respond pkt "kicked" = do
    roomname <- deformatRoom (fromJust $ parameter pkt)
    uname <- use_ name
    modify_ $ removeRoom roomname
    I.sendKick uname (getArg "by" pkt) roomname $ case body pkt of {Just "" -> Nothing; x -> x}

respond pkt "send" = I.sendNotice $ T.concat ["Send error: ", getArg "e" pkt]

respond _ "ping" = get_ >>= \k -> io . writeServer k $ ("pong\n\0" :: T.Text)

respond _ str = klog Yellow $ "Got the packet called " ++ T.unpack str


mkUser :: Chatroom -> PrivclassStore -> Packet -> User
mkUser room st p = User (fromJust $ parameter p)
                       (g "pc")
                       (getPcLevel room (g "pc") st)
                       (g "symbol")
                       (entityDecode $ g "realname")
                       (g "typename")
                       (g "gpc")
    where
        g = flip getArg p

errHandlers :: [Handler KevinIO ()]
errHandlers = [Handler (\(_ :: KevinException) -> klogError "Malformed communication from server"),
               Handler (\(e :: IOException) -> klogError $ "server: " ++ show e)]
