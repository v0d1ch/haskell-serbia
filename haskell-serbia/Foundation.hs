module Foundation where

import Import.NoFoundation
import Database.Persist.Sql (ConnectionPool, runSqlPool)
import Text.Hamlet          (hamletFile)
import Text.Jasmine         (minifym)

import Yesod.Default.Util   (addStaticContentExternal)
import Yesod.Core.Types     (Logger)
import Yesod.Form.Jquery
import qualified Yesod.Core.Unsafe as Unsafe
import qualified Data.CaseInsensitive as CI
import qualified Data.Text.Encoding as TE
import           Control.Applicative      ((<$>), (<*>))
import qualified Data.Monoid                        as DM
import           Control.Monad            (join)
import           Data.Maybe               (isJust)
import qualified Data.Text.Lazy.Encoding
import           Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import           Network.Mail.Mime
import           Text.Hamlet              (shamlet)
import           Text.Shakespeare.Text    (stext)
import Yesod.Auth.Email
import qualified Yesod.Auth.Message       as Msg

data App = App
    { appSettings    :: AppSettings
    , appStatic      :: Static -- ^ Settings for static file serving.
    , appConnPool    :: ConnectionPool -- ^ Database connection pool.
    , appHttpManager :: Manager
    , appLogger      :: Logger
    }

data MenuItem = MenuItem
    { menuItemLabel :: Text
    , menuItemRoute :: Route App
    , menuItemAccessCallback :: Bool
    }

data MenuTypes
    = NavbarLeft MenuItem
    | NavbarRight MenuItem

mkYesodData "App" [parseRoutes|
/static StaticR Static appStatic
/auth   AuthR   Auth   getAuth

/favicon.ico FaviconR GET
/robots.txt RobotsR GET

/ HomeR GET

/profile ProfileR GET

!/tutorials/all TutorialListR GET
!/tutorials/new TutorialsR GET POST
!/tutorial/#TutorialId TutorialRR GET
tutorial/edit/#TutorialId TutorialEditR GET POST
|]

type Form x = Html -> MForm (HandlerT App IO) (FormResult x, Widget)

instance Yesod App where
    approot = ApprootRequest $ \app req ->
        case appRoot $ appSettings app of
            Nothing -> getApprootText guessApproot app req
            Just root -> root

    makeSessionBackend _ = Just <$> defaultClientSessionBackend
        120    -- timeout in minutes
        "config/client_session_key.aes"

    yesodMiddleware = defaultYesodMiddleware

    defaultLayout widget = do
        master <- getYesod
        mmsg <- getMessage

        muser <- maybeAuthPair
        mcurrentRoute <- getCurrentRoute
        pageHeader <- pageHeaderWidget >>= widgetToPageContent

        -- Get the breadcrumbs, as defined in the YesodBreadcrumbs instance.
        (title, parents) <- breadcrumbs

        -- Define the menu items of the header.
        let menuItems =
                [ NavbarLeft $ MenuItem
                    { menuItemLabel = "Home"
                    , menuItemRoute = HomeR
                    , menuItemAccessCallback = True
                    }
                , NavbarLeft $ MenuItem
                    { menuItemLabel = "Tutorials"
                    , menuItemRoute =  TutorialListR
                    , menuItemAccessCallback = isNothing muser
                    }
                , NavbarLeft $ MenuItem
                    { menuItemLabel = "Profile"
                    , menuItemRoute = ProfileR
                    , menuItemAccessCallback = isJust muser
                    }
                , NavbarRight $ MenuItem
                    { menuItemLabel = "Login"
                    , menuItemRoute = AuthR LoginR
                    , menuItemAccessCallback = isNothing muser
                    }
                , NavbarRight $ MenuItem
                    { menuItemLabel = "Logout"
                    , menuItemRoute = AuthR LogoutR
                    , menuItemAccessCallback = isJust muser
                    }
                 , NavbarRight $ MenuItem
                    { menuItemLabel = "Create Tutorial"
                    , menuItemRoute =  TutorialsR
                    , menuItemAccessCallback = isNothing muser
                    }

                ]

        let navbarLeftMenuItems = [x | NavbarLeft x <- menuItems]
        let navbarRightMenuItems = [x | NavbarRight x <- menuItems]

        let navbarLeftFilteredMenuItems = [x | x <- navbarLeftMenuItems, menuItemAccessCallback x]
        let navbarRightFilteredMenuItems = [x | x <- navbarRightMenuItems, menuItemAccessCallback x]

        pc <- widgetToPageContent $ do
            addStylesheet $ StaticR css_bootstrap_css
            $(widgetFile "default-layout")

        withUrlRenderer $(hamletFile "templates/default-layout-wrapper.hamlet")

    -- The page to be redirected to when authentication is required.
    authRoute _ = Just $ AuthR LoginR

    -- Routes not requiring authentication.

    -- isAuthorized (AuthR _) _ = return Authorized
    -- isAuthorized HomeR _ = return Authorized
    -- isAuthorized TutorialListR  _ = return Authorized
    -- isAuthorized (TutorialRR _)  _ = return Authorized
    -- isAuthorized FaviconR _ = return Authorized
    -- isAuthorized RobotsR _ = return Authorized
    -- isAuthorized (StaticR _) _ = return Authorized

    -- isAuthorized ProfileR _ = isAuthenticated
    -- isAuthorized (TutorialEditR _)  _ = isAuthenticated
    -- isAuthorized TutorialsR  _ = isAuthenticated -- return Authorized


    addStaticContent ext mime content = do
        master <- getYesod
        let staticDir = appStaticDir $ appSettings master
        addStaticContentExternal
            minifym
            genFileName
            staticDir
            (StaticR . flip StaticRoute [])
            ext
            mime
            content
      where
        -- Generate a unique filename based on the content itself
        genFileName lbs = "autogen-" ++ base64md5 lbs

    shouldLog app _source level =
        appShouldLogAll (appSettings app)
            || level == LevelWarn
            || level == LevelError

    makeLogger = return . appLogger

    defaultMessageWidget title body = $(widgetFile "default-message-widget")

    -- check if user can have access to page
    isAuthorized route isWrite = do
      mauth <- maybeAuth
      let user =   fmap entityVal mauth
      user `isAuthorizedTo` permissionsRequiredFor route isWrite


-- PERMISSIONS
data Permission = PostTutorial | EditTutorial

writePermission = True
readPermission = False

permissionsRequiredFor :: Route App  -> Bool -> [Permission]
permissionsRequiredFor (TutorialEditR _) writePermission = [EditTutorial]
permissionsRequiredFor (TutorialEditR _) readPermission  = [EditTutorial]
permissionsRequiredFor TutorialsR  writePermission       = [PostTutorial]
permissionsRequiredFor TutorialsR  readPermission        = [PostTutorial]

permissionsRequiredFor             _  _                  = []


isAuthorizedTo :: Maybe User -> [Permission] -> HandlerT App IO AuthResult
_       `isAuthorizedTo` []     = return Authorized
Nothing `isAuthorizedTo` (_:_)  = isAuthenticated
Just u  `isAuthorizedTo` (p:ps) = do
  r <- u `hasPermissionTo` p
  case r of
    Authorized -> Just u `isAuthorizedTo` ps
    _          -> return r

hasPermissionTo :: User -> Permission -> Handler AuthResult
user `hasPermissionTo` PostTutorial
  | userEmail user == "brutallesale@gmail.com" = return Authorized
  | otherwise    = isAuthenticated

user `hasPermissionTo` EditTutorial
  | userEmail user == "brutallesale@gmail.com" = return Authorized
  | otherwise    = isAuthenticated



-- Define breadcrumbs.
instance YesodBreadcrumbs App where
  breadcrumb HomeR = return ("Home", Nothing)
  breadcrumb TutorialListR = return ("All Tutorials", Just HomeR)
  breadcrumb (TutorialRR _) = return ("Tutorial", Just TutorialListR)

  breadcrumb (AuthR _) = return ("Login", Just HomeR)
  breadcrumb ProfileR = return ("Profile", Just HomeR)
  breadcrumb  _ = return ("home", Nothing)

-- How to run database actions.
instance YesodPersist App where
    type YesodPersistBackend App = SqlBackend
    runDB action = do
        master <- getYesod
        runSqlPool action $ appConnPool master


instance YesodPersistRunner App where
    getDBRunner = defaultGetDBRunner appConnPool

instance YesodAuth App where
    type AuthId App = UserId

    loginDest _ = HomeR
    logoutDest _ = HomeR
    redirectToReferer _ = True

    authPlugins _ = [authEmail]



    -- Need to find the UserId for the given email address.
    getAuthId creds = runDB $ do
        x <- insertBy $ User (credsIdent creds) Nothing Nothing False Nothing Nothing
        return $ Just $
            case x of
                Left (Entity userid _) -> userid -- newly added user
                Right userid -> userid -- existing user

    authHttpManager = error "Email doesn't need an HTTP manager"


-- | Access function to determine if a user is logged in.
isAuthenticated :: Handler AuthResult
isAuthenticated = do
    muid <- maybeAuthId
    return $ case muid of
        Nothing -> Unauthorized "You must login to access this page"
        Just _ -> Authorized

instance YesodAuthPersist App

instance RenderMessage App FormMessage where
    renderMessage _ _ = defaultFormMessage

instance HasHttpManager App where
    getHttpManager = appHttpManager

unsafeHandler :: App -> Handler a -> IO a
unsafeHandler = Unsafe.fakeHandlerGetLogger appLogger

instance YesodJquery App


-- CUSTOM WIDGETS
-- header widget
pageHeaderWidget :: Handler Widget
pageHeaderWidget = do
  return $(widgetFile "header/header")


data UserForm = UserForm { _userFormEmail :: Text }
data UserLoginForm = UserLoginForm { _loginEmail :: Text, _loginPassword :: Text }

myRegisterHandler :: HandlerT Auth (HandlerT App IO) Html
myRegisterHandler = do
    (widget, enctype) <- lift $ generateFormPost registrationForm
    toParentRoute <- getRouteToParent
    lift $ defaultLayout $ do
        setTitleI Msg.RegisterLong
        [whamlet|
              <div .col-md-4 .col-md-offset-4>
                <p>_{Msg.EnterEmail}
                <form method="post" action="@{toParentRoute registerR}" enctype=#{enctype}>
                        ^{widget}
                        <div .voffset4>
                          <button .btn .btn-success .btn-sm .pull-right>_{Msg.Register}
        |]
    where
        registrationForm extra = do
            let emailSettings = FieldSettings {
                fsLabel = SomeMessage Msg.Email,
                fsTooltip = Nothing,
                fsId = Just "email",
                fsName = Just "email",
                fsAttrs = [("autofocus", "true"),("class","form-control")]
            }

            (emailRes, emailView) <- mreq emailField emailSettings Nothing

            let userRes = UserForm <$> emailRes
            let widget = do
                [whamlet|
                    #{extra}
                    ^{fvLabel emailView}
                    ^{fvInput emailView}
                |]

            return (userRes, widget) 


myEmailLoginHandler :: (Route Auth -> Route App) -> WidgetT App IO ()
myEmailLoginHandler toParent = do
        (widget, enctype) <- liftWidgetT $ generateFormPost loginForm

        [whamlet|
              <div .col-md-4 .col-md-offset-4>
                <form method="post" action="@{toParent loginR}", enctype=#{enctype}>
                    <div id="emailLoginForm">
                        ^{widget}
                        <div .voffset4>

                            <button type=submit .btn .btn-success .btn-sm>Login
                            &nbsp;
                            <a href="@{toParent registerR}" .btn .btn-default .btn-sm .pull-right>
                                _{Msg.Register}
        |]
  where
    loginForm extra = do

        emailMsg <- renderMessage' Msg.Email
        (emailRes, emailView) <- mreq emailField (emailSettings emailMsg) Nothing

        passwordMsg <- renderMessage' Msg.Password
        (passwordRes, passwordView) <- mreq passwordField (passwordSettings passwordMsg) Nothing

        let userRes = UserLoginForm Control.Applicative.<$> emailRes
                                    Control.Applicative.<*> passwordRes
        let widget = do
            [whamlet|
                #{extra}
                <div>
                    ^{fvInput emailView}
                <div>
                    ^{fvInput passwordView}
            |]

        return (userRes, widget)
    emailSettings emailMsg =
        FieldSettings {
            fsLabel = SomeMessage Msg.Email,
            fsTooltip = Nothing,
            fsId = Just "email",
            fsName = Just "email",
            fsAttrs = [("autofocus", ""), ("placeholder", emailMsg), ("class","form-control")]
        }

    passwordSettings passwordMsg =
         FieldSettings {
            fsLabel = SomeMessage Msg.Password,
            fsTooltip = Nothing,
            fsId = Just "password",
            fsName = Just "password",
            fsAttrs = [("placeholder", passwordMsg), ("class","form-control")]
        }

    renderMessage' msg = do
        langs <- languages
        master <- getYesod
        return $ renderAuthMessage master langs msg


instance YesodAuthEmail App where
    type AuthEmailId App = UserId

    registerHandler = myRegisterHandler

    emailLoginHandler = myEmailLoginHandler

    afterPasswordRoute _ = HomeR

    addUnverified email verkey =
        runDB $ insert $ User email Nothing (Just verkey) False Nothing Nothing

    sendVerifyEmail email _ verurl = do
        liftIO $ putStrLn $ "Copy/ Paste this URL in your browser:" DM.<> verurl
        -- Send email.
        liftIO $ renderSendMail (emptyMail $ Address Nothing "noreply")
            { mailTo = [Address Nothing email]
            , mailHeaders =
                [ ("Subject", "Verify your email address")
                ]
            , mailParts = [[textPart, htmlPart]]
            }
      where
        textPart = Part
            { partType = "text/plain; charset=utf-8"
            , partEncoding = None
            , partFilename = Nothing
            , partContent = Data.Text.Lazy.Encoding.encodeUtf8
                [stext|
                    Please confirm your email address by clicking on the link below.

                    #{verurl}

                    Thank you
                |]
            , partHeaders = []
            }
        htmlPart = Part
            { partType = "text/html; charset=utf-8"
            , partEncoding = None
            , partFilename = Nothing
            , partContent = renderHtml
                [shamlet|
                    <p>Please confirm your email address by clicking on the link below.
                    <p>
                        <a href=#{verurl}>#{verurl}
                    <p>Thank you
                |]
            , partHeaders = []
            }

    getVerifyKey = runDB . fmap (join . fmap userVerkey) . get

    setVerifyKey uid key = runDB $ update uid [UserVerkey =. Just key]

    verifyAccount uid = runDB $ do
        mu <- get uid
        case mu of
            Nothing -> return Nothing
            Just _ -> do
                update uid [UserVerified =. True]
                return $ Just uid

    getPassword = runDB . fmap (join . fmap userPassword) . get

    setPassword uid pass = runDB $ update uid [UserPassword =. Just pass]

    getEmailCreds email = runDB $ do
        mu <- getBy $ UniqueUser email
        case mu of
            Nothing -> return Nothing
            Just (Entity uid u) -> return $ Just EmailCreds
                { emailCredsId = uid
                , emailCredsAuthId = Just uid
                , emailCredsStatus = isJust $ userPassword u
                , emailCredsVerkey = userVerkey u
                , emailCredsEmail = email
                }

    getEmail = runDB . fmap (fmap userEmail) . get






