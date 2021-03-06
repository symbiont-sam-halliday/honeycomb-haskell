{-# LANGUAGE ScopedTypeVariables #-}
module Honeycomb.Core
    (
    -- * Library initialization
    --
    -- $libraryInitialization
      honeyOptionsFromEnv
    , withHoney
    , withHoney'
    , newHoney
    , newHoney'
    , withHoneyOptions

    -- * Events

    -- ** Creating and sending
    , flush

    , module Honeycomb.Core.Types
    )
where

import Control.Monad.Reader (MonadReader, local, void)
import Data.Maybe (isJust)
import qualified Data.Text as T
import Honeycomb.Transport
import Honeycomb.Core.Types
import Lens.Micro (over, (&), (.~))
import Lens.Micro.Mtl (view)
import System.Environment (lookupEnv)
import UnliftIO

{- | Waits until all currently sent events have been dequeued and processed.

This may be useful in a system which suspends processing when idle; the user
may want to guarantee that all queued events have been sent.

This only guarantees that events queued before this call will be sent. A
user may add more events afterwards, and this does not guarantee that those
events have been sent.
-}
flush
    :: ( MonadUnliftIO m
       , MonadReader env m
       , HasHoney env
       )
    => Int  -- ^ Length of time to wait before giving up (in microseconds)
    -> m ()
flush timeout_us = do
    flushQueue <- view $ honeyL . honeyTransportStateL . transportFlushQueueL
    mvar <- newEmptyTMVarIO
    atomically $ writeTBQueue flushQueue mvar
    void $ timeout timeout_us $ atomically $ takeTMVar mvar

{- | Creates a new Honey library instance.

A background thread is started up, which will dequeue events that
need to be sent. On shutdown, the event queue is shut down, and
the background thread stops once all messages are processed. 

Discovers Honey options from the environment; if you wish to set the
options manually, use {{newHoney'}}
-}
newHoney
    :: ( MonadUnliftIO n
       , MonadIO m
       )
    => HoneyServerOptions  -- ^ Options for how event handling is performed
    -> n (Honey, m ())
newHoney honeyServerOptions = do
    honeyOptions <- honeyOptionsFromEnv
    (transportState, shutdown) <- newTransport honeyServerOptions
    pure (mkHoney honeyOptions transportState, shutdown)

{- | Creates a new Honey library instance.

A background thread is started up, which will dequeue events that
need to be sent. On shutdown, the event queue is shut down, and
the background thread stops once all messages are processed. 
-}
newHoney'
    :: ( MonadUnliftIO n
       , MonadIO m
       )
    => HoneyServerOptions  -- ^ Options for how event handling is performed
    -> HoneyOptions        -- ^ Options for client library behaviour
    -> n (Honey, m ())
newHoney' honeyServerOptions honeyOptions = do
    (transportState, shutdown) <- newTransport honeyServerOptions
    pure (mkHoney honeyOptions transportState, shutdown)

{- |
Creates a Honey environment, and if given a program that uses this,
will run the program with an environment, correctly shutting everything
down afterwards.

Discovers Honey options from the environment; if you wish to set the
options manually, use {{withHoney'}} or {{withHoneyOptions}}
-}
withHoney
    :: MonadUnliftIO m
    => HoneyServerOptions  -- ^ Options for how event handling is performed
    -> (Honey -> m a)      -- ^ The program to run
    -> m a
withHoney honeyServerOptions inner = withRunInIO $ \run ->
    bracket (newHoney honeyServerOptions)
            snd
            (run . inner . fst)

{- |
Creates a Honey environment, and if given a program that uses this,
will run the program with an environment, correctly shutting everything
down afterwards.
-}
withHoney'
    :: MonadUnliftIO m
    => HoneyServerOptions  -- ^ Options for how event handling is performed
    -> HoneyOptions        -- ^ Options for client library behaviour
    -> (Honey -> m a)      -- ^ The program to run
    -> m a
withHoney' honeyServerOptions honeyOptions inner = withRunInIO $ \run ->
    bracket (newHoney' honeyServerOptions honeyOptions)
        snd
        (run . inner . fst)

{- | Modifies the HoneyOptions value for the provided program.

This allows a program to be run, with a @HoneyOptions@ value which is different
to the one configured when setting up the library.
-}
withHoneyOptions
    :: ( MonadReader env m
       , HasHoney env
       )
    => (HoneyOptions -> HoneyOptions)  -- ^ The function to modify the current options value
    -> m a                             -- ^ The program to run
    -> m a
withHoneyOptions f = local (over (honeyL . honeyOptionsL) f)

honeyOptionsFromEnv
    :: MonadIO m
    => m HoneyOptions
honeyOptionsFromEnv = do
    apiKeyEnv <- liftIO $ (fmap . fmap) (ApiKey . T.pack) $ lookupEnv "HONEYCOMB_API_KEY"
    datasetEnv <- liftIO $ (fmap . fmap) (Dataset . T.pack) $ lookupEnv "HONEYCOMB_DATASET"
    disabledEnv <- liftIO $ (fmap . fmap) (Dataset . T.pack) $ lookupEnv "HONEYCOMB_DISABLED"
    pure $ defaultHoneyOptions
            & apiKeyL .~ apiKeyEnv
            & datasetL .~ datasetEnv
            & disabledL .~ isJust disabledEnv

