{-# LANGUAGE TypeOperators #-}
module Network.Monitoring.Honeycomb.Wai where

import Network.HTTP.Types.Status (statusCode)
import Network.Wai
import Network.Monitoring.Honeycomb
import Network.Monitoring.Honeycomb.Trace
import RIO

import qualified RIO.HashMap as HM

type ApplicationT m = Request -> (Response -> m ResponseReceived) -> m ResponseReceived
type MiddlewareT m = ApplicationT m -> ApplicationT m

liftApplication :: MonadUnliftIO m => Application -> ApplicationT m
liftApplication app req respond =
    withRunInIO $ \runInIO -> liftIO $ app req (runInIO . respond)

liftMiddleware :: MonadUnliftIO m => Middleware -> MiddlewareT m
liftMiddleware mid app req respond = do
    app' <- runApplicationT app
    withRunInIO $ \runInIO -> mid app' req (runInIO . respond)

runApplicationT :: MonadUnliftIO m => ApplicationT m -> m Application
runApplicationT app =
    withRunInIO $ \runInIO ->
        pure $ \req respond ->
            runInIO $ app req (liftIO . respond)

runMiddlewareT :: MonadUnliftIO m => MiddlewareT m -> m Middleware
runMiddlewareT mid =
    withRunInIO $ \runInIO ->
        pure $ \app req respond -> do
            app' <- runInIO . runApplicationT . mid $ liftApplication app
            app' req respond

traceApplicationT
    :: forall m env .
       ( MonadUnliftIO m
       , MonadReader env m
       , HasHoney env
       , HasTracer env
       )
    => SpanName
    -> MiddlewareT m
traceApplicationT name app req inner =
    withNewRootSpan name (const mempty) $ do
        addToSpan getRequestFields
        (\x y -> app x y `catchAny` reportErrorStatus) req (\response -> do
            addToSpan (getResponseFields response)
            inner response
            )
  where
    getRequestFields :: HoneyObject
    getRequestFields = HM.fromList
        [ ("meta.span_type", HoneyString "http_request")
        , ("request.header.user_agent", maybe HoneyNil (toHoneyValue . decodeUtf8Lenient) (requestHeaderUserAgent req))
        , ("request.host", maybe HoneyNil (toHoneyValue . decodeUtf8Lenient) (requestHeaderHost req))
        , ("request.path", toHoneyValue . decodeUtf8Lenient $ rawPathInfo req)
        ]

    reportErrorStatus :: SomeException -> m a
    reportErrorStatus e = addFieldToSpan "response.status_code" (500 :: Int) >> throwIO e

    getResponseFields :: Response -> HoneyObject
    getResponseFields response = HM.fromList
        [ ("response.status_code", toHoneyValue . statusCode $ responseStatus response)
        ]
