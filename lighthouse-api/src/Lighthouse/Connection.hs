{-# LANGUAGE RecordWildCards #-}
module Lighthouse.Connection (LighthouseIO (..), runLighthouseIO, sendDisplay, sendClose) where

import Control.Monad.Trans (liftIO)
import Control.Monad.Trans.State
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Lighthouse.Authentication
import Lighthouse.Display
import Lighthouse.Event
import Lighthouse.Protocol
import Lighthouse.Utils.Serializable
import Network.Socket (withSocketsDo)
import qualified Network.WebSockets as WS
import qualified Wuss as WSS

-- TODO: Maintain a list of listeners that get notified of key events
--       in this state and use forkIO to receive events from the connection
--       in an infinite loop (using forever).
data ConnectionState = ConnectionState { wsConnection :: WS.Connection, lhAuth :: Authentication }

-- | The central IO monad to be used by Lighthouse applications. Holds a connection.
type LighthouseIO a = StateT ConnectionState IO a

-- | Runs a lighthouse application using the given credentials.
runLighthouseIO :: LighthouseIO a -> Authentication -> IO a
runLighthouseIO lio auth = withSocketsDo $ WSS.runSecureClient "lighthouse.uni-kiel.de" 443 path
                                         $ \conn -> fst <$> (runStateT lio $ ConnectionState { wsConnection = conn, lhAuth = auth })
    where path = "/user/" ++ T.unpack (username auth) ++ "/model"

-- | Sends raw, binary data directly to the lighthouse.
sendBinaryData :: BL.ByteString -> LighthouseIO ()
sendBinaryData d = do
    conn <- wsConnection <$> get
    liftIO $ WS.sendBinaryData conn d

-- | Sends a display request with the given display.
sendDisplay :: Display -> LighthouseIO ()
sendDisplay d = do
    auth <- lhAuth <$> get
    sendBinaryData $ serialize $ displayRequest auth d

-- | Receives a batch of key event from the Lighthouse.
receiveKeyEvents :: LighthouseIO [KeyEvent]
receiveKeyEvents = do
    conn <- wsConnection <$> get
    dat <- liftIO $ WS.receiveData conn
    case deserialize dat of
        Just (FromServerRequest {..}) -> return $ fsPayload
        Just (FromServerResponse {..}) -> do liftIO $ putStrLn $ "Got error from server: " ++ T.unpack fsError
                                             return []
        Nothing -> do liftIO $ putStrLn "Got unrecognized message from server"
                      return []

-- | Sends a close message.
sendClose :: LighthouseIO ()
sendClose = do
    conn <- wsConnection <$> get
    liftIO $ WS.sendCloseCode conn status $ T.pack "end of data"
    where status = 1000 -- normal
