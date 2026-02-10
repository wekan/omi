program wekan;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads, cmem,
  {$ENDIF}
  SysUtils, fphttpapp, HTTPDefs, httproute, Classes;

var
  MongoUrlValue: string;
  CurrentUser: string; // Store current logged in user

function WebBrowserName(const UserAgent: string): String;
// Ubuntu Chrome: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36
// MorphOS IBrowse 3.0a: IBrowse/3.0 (Amiga; MorphOS 3.19; Build 30.8 68K)
// NetSurf 3.11 (28th December 2023): Mozilla/5.0 (X11; Linux) NetSurf/3.11
// FreeDOS Dillo: Mozilla/4.0 (compatible; Dillo 3.0)
// Ubuntu Desktop Dillo:  Dillo/3.0.5
// iPhone: Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1
// Ubuntu Touch Morph Browser: Mozilla/5.0 (Linux; Ubuntu 24.04 like Android 9) AppleWebKit/537.36 Chrome/87.0.4280.144 Mobile Safari/537.36
// Ubuntu Desktop Morph Browser: Mozilla/5.0 (Linux; Ubuntu 25.04) AppleWebKit/537.36 Chrome/87.0.4280.144 Safari/537.36
var
  BrowserName: String;
begin
  BrowserName := '';
  if Pos('IBrowse', UserAgent) > 0 then
  begin
    BrowserName := 'IBrowse';
  end
  else if Pos('NetSurf', UserAgent) > 0 then
  begin
    BrowserName := 'NetSurf';
  end
  else if Pos('Dillo', UserAgent) > 0 then
  begin
    if Pos('Mozilla', UserAgent) > 0 then
    begin
      BrowserName := 'DilloFreeDOS';
    end
    else
    begin
      BrowserName := 'DilloDesktop';
    end
  end
  else if Pos('iPhone', UserAgent) > 0 then
  begin
    BrowserName := 'iPhoneSafari';
  end
  else if Pos('Ubuntu', UserAgent) > 0 then
  begin
    if Pos('Android', UserAgent) > 0 then
    begin
      BrowserName := 'UbuntuTouchMorph';
    end
    else
    begin
      BrowserName := 'UbuntuDesktopMorph';
    end
  end
  else if Pos('Chrome', UserAgent) > 0 then
  begin
    BrowserName := 'Chrome/Brave';
  end
  else
  begin
    BrowserName := 'Unknown';
  end;
  Result := BrowserName;
end;


// Example: Add(BoardIcon('At touchscreen', 1, 'white', 'blue'));
function BoardIcon(BoardTitle: String; TabIndex: Integer; Color: String; BackgroundColor: String): String;
begin
  Result := '<table bgcolor="' + BackgroundColor + '" tabindex="' + IntToStr(TabIndex) + '" style="border-collapse: collapse;" width="200"' +
            ' height="80" border="0" padding="0" spacing="0" id="drag-' + IntToStr(TabIndex) + '" class="draggable" border-collapse="collapse">' + LineEnding +
          '  <tbody>' + LineEnding +
          '    <tr border="0" padding="0" spacing="0">' + LineEnding +
          '      <td width="20" height="20"></td>' + LineEnding +
          '      <td width="160" height="40" valign="middle" align="top"><font size="1" color="' + Color + '" face="arial"><b>' + BoardTitle + '</b><p></p></font></td>' + LineEnding +
          '      <td width="20" height="20"></td>' + LineEnding +
          '    </tr>' + LineEnding +
          '    <tr border="0" padding="0" spacing="0">' + LineEnding +
          '      <td width="20" height="20"></td>' + LineEnding +
          '      <td width="160" height="20"></td>' + LineEnding +
          '      <td width="20" height="20"></td>' + LineEnding +
          '    </tr>' + LineEnding +
          '    <tr border="0" padding="0" spacing="0">' + LineEnding +
          '      <td width="20" height="20"></td>' + LineEnding +
          '      <td width="160" height="20"></td>' + LineEnding +
          '      <td width="20" height="20"></td>' + LineEnding +
          '    </tr>' + LineEnding +
          '  </tbody>' + LineEnding +
          '</table>' + LineEnding +
          '<br>' + LineEnding;
end;

function DrawLine(X1: Integer; Y1: Integer; X2: Integer; Y2: Integer; Width: Integer; Height: Integer; Color: String; StrokeWidth: String): String;
begin
  // Color can be for example red or rgb(255,0,0) depending how it's defined
  // Strokewidth usually is 2
  // Example: DrawLine(0,0,270,150,500,210,'red','2');
  Result := '<div class="lines">' + LineEnding +
            '  <svg width="' + IntToStr(Width) + '" height="' + IntToStr(Height) + '">' + LineEnding +
            '    <line x1="' + IntToStr(X1) + '" y1="' + IntToStr(Y1) + '" x2="' + IntToStr(X2) + '" y2="' + IntToStr(Y2) + '" style="stroke:' + Color + ';stroke-width:' + StrokeWidth + '" />' + LineEnding +
            '  </svg>' + LineEnding +
            '  <v:group coordorigin="' + IntToStr(X1) + ' ' + IntToStr(Y1) + '" coordsize="' + IntToStr(Width) + ' ' + IntToStr(Height) + '" style="width:' + IntToStr(Width) + 'px;height:' + IntToStr(Height) + 'px;">' + LineEnding +
            '    <v:line from="' + IntToStr(X1) + ',' + IntToStr(Y1) + '" to="' + IntToStr(X2) + ',' + IntToStr(Y2) + '" strokecolor="' + Color + '" strokeweight="' + StrokeWidth + 'pt" />' + LineEnding +
            '  </v:group>' + LineEnding +
            '</div>' + LineEnding;
end;

function InitializeUserStorage: Boolean;
begin
  // Create users directory if it doesn't exist
  if not DirectoryExists('wekandata') then
  begin
    CreateDir('wekandata');
    Writeln('Created wekandata directory');
  end;

  // Create users.csv file if it doesn't exist
  if not FileExists('wekandata/users.csv') then
  begin
    with TStringList.Create do
    try
      Add('admin:admin:admin@example.com:false'); // Default admin user
      SaveToFile('wekandata/users.csv');
      Writeln('Created users file with default admin account');
    finally
      Free;
    end;
  end;

  Result := True;
  Writeln('File-based user storage initialized successfully');
end;

function RegisterUser(const Username, Email, Password: string): Boolean;
var
  UsersFile: TStringList;
  UserLine: string;
  i: Integer;
begin
  Result := False;
  try
    UsersFile := TStringList.Create;
    try
      if FileExists('wekandata/users.csv') then
        UsersFile.LoadFromFile('wekandata/users.csv');
      // Check if user already exists
      for i := 0 to UsersFile.Count - 1 do
      begin
        if Pos(Username + ':', UsersFile[i]) = 1 then
        begin
          Writeln('User already exists: ' + Username);
          Exit;
        end;
      end;
      // Add new user (format: username:password:email:isAdmin)
      UserLine := Username + ':' + Password + ':' + Email + ':false';
      UsersFile.Add(UserLine);
      UsersFile.SaveToFile('wekandata/users.csv');
      Writeln('User registered successfully: ' + Username);
      Result := True;
    finally
      UsersFile.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('Error registering user: ' + E.Message);
      Result := False;
    end;
  end;
end;

function AuthenticateUser(const Username, Password: string): Boolean;
var
  UsersFile: TStringList;
  UserLine: string;
  i: Integer;
  Parts: TStringArray;
begin
  Result := False;
  try
    UsersFile := TStringList.Create;
    try
      if FileExists('wekandata/users.csv') then
        UsersFile.LoadFromFile('wekandata/users.csv');
      // Check each user line
      for i := 0 to UsersFile.Count - 1 do
      begin
        UserLine := UsersFile[i];
        if Pos(Username + ':', UserLine) = 1 then
        begin
          // Parse user line (format: username:password:email:isAdmin)
          Parts := UserLine.Split([':']);
          if (Length(Parts) >= 2) and (Parts[1] = Password) then
          begin
            Result := True;
            CurrentUser := Username;
            Writeln('User authenticated successfully: ' + Username);
            Exit;
          end;
        end;
      end;
      Writeln('Authentication failed for: ' + Username);
    finally
      UsersFile.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('Error authenticating user: ' + E.Message);
      Result := False;
    end;
  end;
end;

function UserExists(const Username: string): Boolean;
var
  UsersFile: TStringList;
  i: Integer;
begin
  Result := False;
  try
    UsersFile := TStringList.Create;
    try
      if FileExists('wekandata/users.csv') then
        UsersFile.LoadFromFile('wekandata/users.csv');
      // Check if user exists
      for i := 0 to UsersFile.Count - 1 do
      begin
        if Pos(Username + ':', UsersFile[i]) = 1 then
        begin
          Result := True;
          Writeln('User already exists: ' + Username);
          Exit;
        end;
      end;
    finally
      UsersFile.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('Error checking if user exists: ' + E.Message);
      Result := False;
    end;
  end;
end;

procedure catchallEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content:='This endpoint is not available';
  aResponse.Code:=404;
  aResponse.ContentType:='text/plain';
  aResponse.ContentLength:=Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure allPagesEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  MongoUrlValue := GetEnvironmentVariable('MONGO_URL');
  if MongoUrlValue <> '' then
  begin
    Writeln('MONGO_URL environment variable value:');
    Writeln(MongoUrlValue);
  end
  else
  begin
    Writeln('MONGO_URL environment variable not found.');
  end;
  aResponse.Content := '';
  with aResponse.Contents do
  begin
    Add('<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">');
    Add('<html><head><title>WeKan</title></head><body>');
    Add('WeKan');
    Add('<p>Serverside UserAgent: ' + aRequest.UserAgent);
    Writeln('Serverside UserAgent: ' + aRequest.UserAgent);
    Add('<p>Detected Browser: ' + WebBrowserName(aRequest.UserAgent) + '</p>');
    Writeln('Detected Browser: ' + WebBrowserName(aRequest.UserAgent));
    Add('<p>Serverside IPv4: ' + aRequest.RemoteAddr + '</p>');
    Writeln('Serverside IPv4: ' + aRequest.RemoteAddr);
    // New code to show screen width and height
    Add('<p><noscript><p>Browser does not support Javascript</noscript><script>document.write("Browser supports Javascript");</script>');
    Add('<p><span id="screenInfo"></span></p>');
    Add('<script language="JavaScript">');
    Add('function showBrowserWindowSize() {');
    Add('  var myWidth = 0, myHeight = 0;');
    Add('  if (typeof window.innerWidth === "number") {');
    Add('    myWidth = window.innerWidth;');
    Add('    myHeight = window.innerHeight;');
    Add('  } else {');
    Add('    myWidth = document.documentElement.clientWidth || document.body.clientWidth;');
    Add('    myHeight = document.documentElement.clientHeight || document.body.clientHeight;');
    Add('  }');
    Add('  document.getElementById("screenInfo").innerHTML = "Browser Javascript: window inner size: " + myWidth + " x " + myHeight;');
    Add('}');
    Add('window.onload = showBrowserWindowSize;');
    // Chrome: Shows window size
    // Netsurf: Supports document.write, but window size: undefined x undefined
    // IBrowse: Supports document.write, but does not show window size text at all
    Add('</script>');
    Add('<p><a href=".">All Pages</a> - <a href="multidrag/">Multidrag</a></p>');
    Add('<p><b>Login</b>: <a href="sign-in">Sign In</a>');
    Add(' - <a href="sign-up">Sign Up</a>');
    Add(' - <a href="forgot-password">Forgot Password</a></p>');
    Add('<p><b>Boards</b>: <a href="allboards">All Boards</a>');
    Add(' - <a href="public">Public</a> - <a href="/board">Board</a>');
    Add(' - <a href="shortcuts">Shortcuts</a>');
    Add(' - <a href="templates">Templates</a></p>');
    Add('<p><b>Cards</b>: <a href="my-cards">My Cards</a>');
    Add(' - <a href="due-cards">Due Cards</a>');
    Add(' - <a href="import">Import</a></p>');
    Add('<p><b><a href="calendar">Calendar</a></b></p>');
    Add('<p><b>Upload</b>: <a href="upload">Upload</a></p>');
    Add('<p><b>Search</b>: <a href="global-search">Global Search</a></p>');
    Add('<p><b>Accessibility</b>: <a href="accessibility">Accessibility Features</a></p>');
    Add('<p><b>Admin</b>: <a href="broken-cards">Broken Cards</a>');
    Add(' - <a href="setting">Setting</a>');
    Add(' - <a href="information">Information</a>');
    Add(' - <a href="people">People</a>');
    Add(' - <a href="admin-reports">Admin Reports</a>');
    Add('- <a href="attachments">Attachments</a>');
    Add(' - <a href="translation">Translation</a></p>');
    Add('</body></html>');
  end;
  aResponse.Code:=200;
  aResponse.ContentType:='text/html';
  aResponse.ContentLength:=Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure screenInfoEndpoint(aRequest: TRequest; aResponse: TResponse);
var
  ScreenWidth, ScreenHeight: string;
begin
  ScreenWidth := aRequest.ContentFields.Values['width'];
  ScreenHeight := aRequest.ContentFields.Values['height'];
  aResponse.Content := Format('Screen Width: %s, Screen Height: %s', [ScreenWidth, ScreenHeight]);
  aResponse.ContentType := 'text/plain';
  aResponse.SendContent;
end;

procedure loginEndpoint(aRequest: TRequest; aResponse: TResponse);
var
  Username, Password: string;
  LoginMessage: string;
begin
  if aRequest.Method = 'POST' then
  begin
    // Handle form submission
    Username := aRequest.ContentFields.Values['username'];
    Password := aRequest.ContentFields.Values['password'];
    // Basic validation
    if (Username = '') or (Password = '') then
    begin
      LoginMessage := '<p style="color: red;">Username and password are required.</p>';
    end
    else
    begin
      // Authenticate user against database
      if AuthenticateUser(Username, Password) then
      begin
        // Login successful, redirect to All Boards page
        aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                            '<html><head><title>Login Successful - WeKan</title>' + LineEnding +
                            '<meta http-equiv="refresh" content="2;url=allboards">' + LineEnding +
                            '</head><body>' + LineEnding +
                            '<h1>Login Successful!</h1>' + LineEnding +
                            '<p>Welcome back, ' + Username + '!</p>' + LineEnding +
                            '<p>You will be redirected to the All Boards page in 2 seconds...</p>' + LineEnding +
                            '<p><a href="allboards">Click here if you are not redirected automatically</a></p>' + LineEnding +
                            '<p><a href=".">Back to Home</a></p>' + LineEnding +
                            '</body></html>';
        aResponse.Code := 200;
        aResponse.ContentType := 'text/html';
        aResponse.ContentLength := Length(aResponse.Content);
        aResponse.SendContent;
        Exit; // Exit early for successful login
      end
      else
      begin
        LoginMessage := '<p style="color: red;">Invalid username or password. Please try again.</p>';
      end;
    end;
    // If validation failed or authentication failed, show the form again with error message
    aResponse.Content := '';
    with aResponse.Contents do
    begin
      Add('<p></p>');
      Add('<center>');
      Add('  <table border="0" padding="0" spacing="0" margin="0">');
      Add('    <tr>');
      Add('      <td style="background-color: #f7f7f7;">');
      Add('        <h1 style="font-size: 140%; padding-top: 10px;');
      Add('                   padding-left: 20px; padding-bottom: 0px;">');
      Add('          Login');
      Add('        </h1>');
      Add('      </td>');
      Add('    </tr>');
      Add('    <tr>');
      Add('      <td style="padding-top: 20px; padding-left: 20px;');
      Add('                 padding-right: 20px; background-color: white;">');
      Add('        <form    role="form"');
      Add('                 novalidate');
      Add('                 action="sign-in"');
      Add('                 method="POST">');
      Add('          <div class="form-group">');
      Add('            <label for="username">Username or Email</label>');
      Add('            <input type="text"');
      Add('                   class="form-control"');
      Add('                   id="username"');
      Add('                   name="username"');
      Add('                   value="' + Username + '"');
      Add('                   placeholder="Enter username or email"');
      Add('                   required>');
      Add('          </div>');
      Add('          <div class="form-group">');
      Add('            <label for="password">Password</label>');
      Add('            <input type="password"');
      Add('                   class="form-control"');
      Add('                   id="password"');
      Add('                   name="password"');
      Add('                   placeholder="Enter password"');
      Add('                   required>');
      Add('          </div>');
      Add('          <button type="submit"');
      Add('                  class="btn btn-primary btn-block">');
      Add('            Sign In');
      Add('          </button>');
      Add('        </form>');
      Add(LoginMessage);
      Add('        <p><a href="sign-up">Need an account? Sign up</a></p>');
      Add('        <p><a href="forgot-password">Forgot your password?</a></p>');
      Add('        <p><a href=".">Back to Home</a></p>');
      Add('      </td>');
      Add('    </tr>');
      Add('  </table>');
      Add('</center>');
    end;
  end
  else
  begin
    // Show login form (GET request)
    aResponse.Content := '';
    with aResponse.Contents do
    begin
      Add('<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">');
      Add('<html>');
      Add('  <head>');
      Add('    <title>WeKan</title>');
      Add('    <style type="text/css">');
      Add('      body   { font-family: arial, sans-serif; font-size: 1.2em; }');
      Add('      h1     { font-size: 2.5em; }');
      Add('      input  { font-size: 1em; padding: 0.5em; }');
      Add('      button { font-size: 1.2em; }');
      Add('    </style>');
      Add('</head>');
      Add('<body bgcolor="#ffffff">');
      Add('  <center>');
      Add('    <h1>WeKan</h1>');
      Add('    <form role="form" novalidate action="sign-in" method="POST">');
      Add('      <label for="username">Username or Email</label><br>');
      Add('      <input type="text" id="username" name="username" ');
      Add('             placeholder="Enter username or email" required><br><br>');
      Add('      <label for="password">Password</label><br>');
      Add('      <input type="password" id="password" name="password" ');
      Add('             placeholder="Enter password" required><br><br>');
      Add('      <button type="submit" class="btn btn-primary btn-block">Sign In</button><br><br>');
      Add('    </form>');
      Add('    <p><a href="sign-up">Need an account? Sign up</a></p>');
      Add('    <p><a href="forgot-password">Forgot your password?</a></p>');
      Add('  </center>');
      Add('</body>');
      Add('</html>')
    end;
  end;
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure registerEndpoint(aRequest: TRequest; aResponse: TResponse);
var
  Username, Email, Password, ConfirmPassword: string;
  SuccessMessage: string;
begin
  if aRequest.Method = 'POST' then
  begin
    // Handle form submission
    Username := aRequest.ContentFields.Values['username'];
    Email := aRequest.ContentFields.Values['email'];
    Password := aRequest.ContentFields.Values['password'];
    ConfirmPassword := aRequest.ContentFields.Values['confirm_password'];
    // Basic validation
    if (Username = '') or (Email = '') or (Password = '') then
    begin
      SuccessMessage := '<p style="color: red;">All fields are required.</p>';
    end
    else if Password <> ConfirmPassword then
    begin
      SuccessMessage := '<p style="color: red;">Passwords do not match.</p>';
    end
    else if Length(Password) < 6 then
    begin
      SuccessMessage := '<p style="color: red;">Password must be at least 6 characters long.</p>';
    end
    else if UserExists(Username) then
    begin
      SuccessMessage := '<p style="color: red;">Username already exists. Please choose a different username.</p>';
    end
    else
    begin
      // Register user in database
      if RegisterUser(Username, Email, Password) then
      begin
        // Set current user and redirect to All Boards page
        CurrentUser := Username;
        aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                            '<html><head><title>Registration Successful - WeKan</title>' + LineEnding +
                            '<meta http-equiv="refresh" content="2;url=allboards">' + LineEnding +
                            '</head><body>' + LineEnding +
                            '<h1>Registration Successful!</h1>' + LineEnding +
                            '<p>Welcome, ' + Username + '! Your account has been created successfully.</p>' + LineEnding +
                            '<p>You will be redirected to the All Boards page in 2 seconds...</p>' + LineEnding +
                            '<p><a href="allboards">Click here if you are not redirected automatically</a></p>' + LineEnding +
                            '<p><a href=".">Back to Home</a></p>' + LineEnding +
                            '</body></html>';
        aResponse.Code := 200;
        aResponse.ContentType := 'text/html';
        aResponse.ContentLength := Length(aResponse.Content);
        aResponse.SendContent;
        Exit; // Exit early for successful registration
      end
      else
      begin
        SuccessMessage := '<p style="color: red;">Failed to create account. Please try again.</p>';
      end;
    end;
    // If validation failed or registration failed, show the form again with error message
    aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                        '<html><head><title>Sign Up - WeKan</title></head><body>' + LineEnding +
                        '<h1>Sign Up</h1>' + LineEnding +
                        SuccessMessage + LineEnding +
                        '<form action="sign-up" method="POST">' + LineEnding +
                        '  <label for="username">Username:</label><br>' + LineEnding +
                        '  <input type="text" id="username" name="username" value="' + Username + '" required><br><br>' + LineEnding +
                        '  <label for="email">Email:</label><br>' + LineEnding +
                        '  <input type="email" id="email" name="email" value="' + Email + '" required><br><br>' + LineEnding +
                        '  <label for="password">Password:</label><br>' + LineEnding +
                        '  <input type="password" id="password" name="password" required><br><br>' + LineEnding +
                        '  <label for="confirm_password">Confirm Password:</label><br>' + LineEnding +
                        '  <input type="password" id="confirm_password" name="confirm_password" required><br><br>' + LineEnding +
                        '  <input type="submit" value="Sign Up">' + LineEnding +
                        '</form>' + LineEnding +
                        '<p><a href="sign-in">Already have an account? Sign in</a></p>' + LineEnding +
                        '<p><a href=".">Back to Home</a></p>' + LineEnding +
                        '</body></html>';
  end
  else
  begin
    // Show registration form (GET request)
        aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                            '<html>' + LineEnding +
                            '  <head>' + LineEnding +
                            '    <title>Sign Up - WeKan</title>' + LineEnding +
                            '    <style type="text/css">' + LineEnding +
                            '      body   { font-family: arial, sans-serif; font-size: 1.2em; }' + LineEnding +
                            '      h1     { font-size: 2.5em; }' + LineEnding +
                            '      input  { font-size: 1em; padding: 0.5em; }' + LineEnding +
                            '      button { font-size: 1.2em; }' + LineEnding +
                            '    </style>' + LineEnding +
                            '</head>' + LineEnding +
                            '<body bgcolor="#ffffff">' + LineEnding +
                            '  <center>' + LineEnding +
                            '    <h1>Sign Up</h1>' + LineEnding +
                            '    <form action="sign-up" method="POST">' + LineEnding +
                            '      <label for="username">Username:</label><br>' + LineEnding +
                            '      <input type="text" id="username" name="username" required><br><br>' + LineEnding +
                            '      <label for="email">Email:</label><br>' + LineEnding +
                            '      <input type="email" id="email" name="email" required><br><br>' + LineEnding +
                            '      <label for="password">Password:</label><br>' + LineEnding +
                            '      <input type="password" id="password" name="password" required><br><br>' + LineEnding +
                            '      <label for="confirm_password">Confirm Password:</label><br>' + LineEnding +
                            '      <input type="password" id="confirm_password" name="confirm_password" required><br><br>' + LineEnding +
                            '      <input type="submit" value="Sign Up">' + LineEnding +
                            '      </form>' + LineEnding +
                            '    <p><a href="sign-in">Already have an account? Sign in</a></p>' + LineEnding +
                            '    <p><a href="forgot-password">Forgot password?</a></p>' + LineEnding +
                            '  </center>' + LineEnding +
                            '</body>' + LineEnding +
                            '</html>';

  end;
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure forgotPasswordEndpoint(aRequest: TRequest; aResponse: TResponse);
var
  Email: string;
  ResetMessage: string;
begin
  if aRequest.Method = 'POST' then
  begin
    // Handle form submission
    Email := aRequest.ContentFields.Values['email'];
    // Basic validation
    if Email = '' then
    begin
      ResetMessage := '<p style="color: red;">Email address is required.</p>';
    end
    else if Pos('@', Email) = 0 then
    begin
      ResetMessage := '<p style="color: red;">Please enter a valid email address.</p>';
    end
    else
    begin
      // TODO: Add actual password reset functionality
      ResetMessage := '<p style="color: green;">Password reset instructions have been sent to ' + Email + '.</p>' +
                     '<p>Check your email for further instructions.</p>';
    end;
    aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                        '<html><head><title>Forgot Password - WeKan</title></head><body>' + LineEnding +
                        '<h1>Forgot Password</h1>' + LineEnding +
                        ResetMessage + LineEnding +
                        '<p>Enter your email address to reset your password:</p>' + LineEnding +
                        '<form action="forgot-password" method="POST">' + LineEnding +
                        '  <label for="email">Email:</label><br>' + LineEnding +
                        '  <input type="email" id="email" name="email" value="' + Email + '" required><br><br>' + LineEnding +
                        '  <input type="submit" value="Reset Password">' + LineEnding +
                        '</form>' + LineEnding +
                        '<p><a href="sign-in">Back to Sign In</a></p>' + LineEnding +
                        '<p><a href=".">Back to Home</a></p>' + LineEnding +
                        '</body></html>';
  end
  else
  begin
    // Show password reset form (GET request)
    aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                        '<html><head><title>Forgot Password - WeKan</title></head><body>' + LineEnding +
                        '<h1>Forgot Password</h1>' + LineEnding +
                        '<p>Enter your email address to reset your password:</p>' + LineEnding +
                        '<form action="forgot-password" method="POST">' + LineEnding +
                        '  <label for="email">Email:</label><br>' + LineEnding +
                        '  <input type="email" id="email" name="email" required><br><br>' + LineEnding +
                        '  <input type="submit" value="Reset Password">' + LineEnding +
                        '</form>' + LineEnding +
                        '<p><a href="sign-in">Back to Sign In</a></p>' + LineEnding +
                        '<p><a href=".">Back to Home</a></p>' + LineEnding +
                        '</body></html>';
  end;
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure uploadEndpoint(aRequest: TRequest; aResponse: TResponse);
const
  UPLOAD_FORM = 
    '<form action="/upload" method="post" enctype="multipart/form-data">' +
    '<input type="file" name="file" required>' +
    '<input type="submit" value="Upload">' +
    '</form>';
  BUFFER_SIZE = 16384; // 16KB buffer
var
  ContentType: string;
  UploadStream: TFileStream;
  Buffer: array[0..BUFFER_SIZE-1] of Byte;
  BytesRead: Integer;
  FileName: string;
  UploadDir: string;
begin
  if aRequest.Method = 'GET' then
  begin
    // Show upload form
    aResponse.Content := UPLOAD_FORM;
    aResponse.Code := 200;
    aResponse.ContentType := 'text/html';
    aResponse.ContentLength := Length(aResponse.Content);
    aResponse.SendContent;
    Exit;
  end;
  if aRequest.Method = 'POST' then
  begin
    ContentType := aRequest.ContentType;
    if Pos('multipart/form-data', ContentType) = 0 then
    begin
      aResponse.Code := 400;
      aResponse.Content := 'Invalid content type';
      aResponse.SendContent;
      Exit;  
    end;
    try
      // Create uploads directory if it doesn't exist
      UploadDir := 'uploads';
      if not DirectoryExists(UploadDir) then
      begin
        if not CreateDir(UploadDir) then
        begin
          aResponse.Code := 500;
          aResponse.Content := 'Failed to create upload directory';
          aResponse.SendContent;
          Exit;
        end;
      end;
      // Parse multipart form data to get filename
      FileName := ExtractFileName(aRequest.Files[0].FileName);
      // Create output file stream
      UploadStream := TFileStream.Create('uploads/' + FileName, fmCreate);
      try
        // Stream file data in chunks
        while True do
        begin
          BytesRead := aRequest.Files[0].Stream.Read(Buffer, BUFFER_SIZE);
          if BytesRead = 0 then Break;
          UploadStream.WriteBuffer(Buffer, BytesRead);
        end;
        aResponse.Code := 200;
        aResponse.Content := 'File uploaded successfully';
      finally
        UploadStream.Free;
      end;
    except
      on E: Exception do
      begin
        aResponse.Code := 500;
        aResponse.Content := 'Upload failed: ' + E.Message;
      end;
    end;
    aResponse.ContentType := 'text/plain';
    aResponse.ContentLength := Length(aResponse.Content);
    aResponse.SendContent;
  end;
end;

procedure userSettingsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>User Settings - WeKan</title></head><body>' + LineEnding +
                      '<h1>User Settings</h1>' + LineEnding +
                      '  <table border="0" cellspacing="0" cellpadding="10" width="100%" id="bodytable">' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td colspan="8" valign="top" valign="center" align="left" bgcolor="#2573a7">' + LineEnding +
                      '        <img src="images/logo-header.png" alt="WeKan ®" title="WeKan ®">  ' + LineEnding +
                      '        <img src="font/arrow/white/home.gif" width="20" height="20">' + LineEnding +
                      '        <font size="3" color="#FFFFFF" face="arial">All Boards</font>  ' + LineEnding +
                      '        <a title="Show desktop drag handles" alt="Show desktop drag handles" href="#" aria-label="Show desktop drag handles">' + LineEnding +
                      '          <img src="font/arrow/white/arrows.gif" width="20" height="20">' + LineEnding +
                      '          <img src="font/arrow/white/ban.gif" width="20" height="20">' + LineEnding +
                      '        </a>  ' + LineEnding +
                      '        <a href="notifications" name="Notifications"><img src="font/notification/white/bell.gif" width="20" height="20"></a>  ' + LineEnding +
                      '        <a href="usersettings" name="UserSettings"><img src="font/setting/white/cog.gif" width="20" heigth="20">  ' + LineEnding +
                      '        <font size="3" color="#FFFFFF" face="arial">User Name</font></a>' + LineEnding +
                      '      </td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td colspan="8" bgcolor="#2980b9"><font size="5" color="#FFFFFF" face="arial"><b>User Settings</b></font></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '  </table>' + LineEnding +
                      '</body>' + LineEnding +
                      '</html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure notificationsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Notifications - WeKan</title></head><body>' + LineEnding +
                      '<h1>Notifications</h1>' + LineEnding +
                      '  <table border="0" cellspacing="0" cellpadding="10" width="100%" id="bodytable">' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td colspan="8" valign="top" valign="center" align="left" bgcolor="#2573a7">' + LineEnding +
                      '        <img src="images/logo-header.png" alt="WeKan ®" title="WeKan ®"><img src="font/arrow/white/home.gif" width="20" height="20">' + LineEnding +
                      '        <font size="3" color="#FFFFFF" face="arial">All Boards</font>' + LineEnding +
                      '        <a href="/b/D2SzJKZDS4Z48yeQH/wekan-r-open-source-kanban-board-with-mit-license">' + LineEnding +
                      '        <font size="3" color="#FFFFFF" face="arial">WeKan ® Open Source Kanban board with MIT license</font></a> ' + LineEnding +
                      '        <a href="/b/JctQEtkayWXTTJyzt/wekan-multiverse"><font size="3" color="#FFFFFF" face="arial">WeKan Multiverse</font></a> ' + LineEnding +
                      '        <a title="Show desktop drag handles" alt="Show desktop drag handles" href="#" aria-label="Show desktop drag handles">' + LineEnding +
                      '        <img src="font/arrow/white/arrows.gif" width="20" height="20"> <img src="font/arrow/white/ban.gif" width="20" height="20"></a> ' + LineEnding +
                      '        <a href="notifications" name="Notifications"><img src="font/notification/white/bell.gif" width="20" height="20"></a> ' + LineEnding +
                      '        <a href="usersettings" name="UserSettings"><img src="font/setting/white/cog.gif" width="20" heigth="20"> ' + LineEnding +
                      '        <font size="3" color="#FFFFFF" face="arial">User Name</font></a>' + LineEnding +
                      '      </td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td colspan="8" bgcolor="#2980b9"><font size="5" color="#FFFFFF" face="arial"><b>Notifications</b></font></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '  </table>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure allBoardsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>All Boards - WeKan</title></head><body>' + LineEnding +
                      '<table border="0" cellspacing="0" cellpadding="10" width="100%" bgcolor="#2573a7">' + LineEnding +
                      '  <tr>' + LineEnding +
                      '    <td align="left" valign="middle">' + LineEnding +
                      '      <img src="images/logo-header.png" alt="WeKan" title="WeKan">&nbsp;' + LineEnding +
                      '      <a href="#"><img src="font/arrow/white/home.gif" width="20"><font size="3" color="#FFFFFF" face="arial">All Boards</font></a>&nbsp;' + LineEnding +
                      '    </td>' + LineEnding +
                      '    <td align="right" valign="middle">' + LineEnding;
  
  if CurrentUser <> '' then
  // This All Boards page has been tested to be visible at: Amiga IBrowse, FreeDOS Dillo, Linux Dillo/Netsurf/Chrome'
  // TODO: At IBrowse, cards are at 1 list only. Change to be at different lists.
  begin
    aResponse.Content := aResponse.Content + '<font size="3" color="#FFFFFF" face="arial">Welcome, ' + CurrentUser + '</font>&nbsp;' + LineEnding +
                        '<a href="usersettings" name="UserSettings"><img src="font/setting/white/cog.gif" width="20" height="20"></a>&nbsp;' + LineEnding +
                        '<a href="notifications" name="Notifications"><img src="font/notification/white/bell.gif" width="20" height="20"></a>&nbsp;' + LineEnding +
                        '<a href="logout"><font size="3" color="#FFFFFF" face="arial">Logout</font></a>';
  end
  else
  begin
    aResponse.Content := aResponse.Content + '<a href="sign-in"><font size="3" color="#FFFFFF" face="arial">Sign In</font></a>&nbsp;' + LineEnding +
                        '<a href="sign-up"><font size="3" color="#FFFFFF" face="arial">Sign Up</font></a>';
  end;
  aResponse.Content := aResponse.Content + '    </td>' + LineEnding +
                      '  </tr>' + LineEnding +
                      '  <tr>' + LineEnding +
                      '    <td colspan="2" bgcolor="#2980b9"><font size="5" color="#FFFFFF" face="arial"><b>My Boards</b></font></td>' + LineEnding +
                      '  </tr>' + LineEnding +
                      '</table>' + LineEnding +
                      '<br>' + LineEnding +
                      '<table border="0" padding="0" spacing="0" width="100%">' + LineEnding +
                      '  <tbody>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td width="20" height="20"></td>' + LineEnding +
                      '      <td width="400" height="80" valign="middle" align="center">' + LineEnding +
                      '        <font size="3" color="#666666" face="arial">No boards yet. Create your first board to get started!</font>' + LineEnding +
                      '      </td>' + LineEnding +
                      '      <td width="20" height="20"></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '  </tbody>' + LineEnding +
                      '</table>' + LineEnding +
                      '<br>' + LineEnding +
                      '<p align="center"><a href="board"><font size="3" color="#007bff" face="arial">Create New Board</font></a></p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure publicEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Public Boards - WeKan</title></head><body>' + LineEnding +
                      '<h1>Public Boards</h1>' + LineEnding +
                      '<p>Public boards will be displayed here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure boardEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Board - WeKan</title></head><body>' + LineEnding +
                      '<h1>Kanban Board</h1>' + LineEnding +

                      '<style>' + LineEnding +
                      '  .swimlane { margin-bottom: 20px; }' + LineEnding +
                      '  .kanban-lists-container {' + LineEnding +
                      '    display: flex;' + LineEnding +
                      '    flex-direction: row;' + LineEnding +
                      '    gap: 20px;' + LineEnding +
                      '    overflow-x: auto;' + LineEnding +
                      '  }' + LineEnding +
                      '  .kanban-list {' + LineEnding +
                      '    min-width: 250px;' + LineEnding +
                      '    background: #f4f4f4;' + LineEnding +
                      '    padding: 10px;' + LineEnding +
                      '    border-radius: 4px;' + LineEnding +
                      '  }' + LineEnding +
                      '  .selected {' + LineEnding +
                      '    outline: 2px solid #0066ff;' + LineEnding +
                      '    box-shadow: 0 0 5px rgba(0,102,255,0.5' + LineEnding +
                      '  }' + LineEnding +
                      '  .moving {' + LineEnding +
                      '    opacity: 0.7;' + LineEnding +
                      '    background: #e0e0e0;' + LineEnding +
                      '  }' + LineEnding +
                      '  .kanban-card {' + LineEnding +
                      '    background: white;' + LineEnding +
                      '    padding: 8px;' + LineEnding +
                      '    margin: 8px 0;' + LineEnding +
                      '    border-radius: 3px;' + LineEnding +
                      '    box-shadow: 0 1px 3px rgba(0,0,0,0.12' + LineEnding +
                      '    cursor: pointer;' + LineEnding +
                      '  }' + LineEnding +
                      '  .card-placeholder {' + LineEnding +
                      '    border: 2px dashed #ccc;' + LineEnding +
                      '    background: #f9f9f9;' + LineEnding +
                      '    height: 30px;' + LineEnding +
                      '    margin: 8px 0;' + LineEnding +
                      '  }' + LineEnding +
                      '  .swimlane-placeholder {' + LineEnding +
                      '    border: 2px dashed #ccc;' + LineEnding +
                      '    background: #f9f9f9;' + LineEnding +
                      '    height: 50px;' + LineEnding +
                      '    margin-bottom: 20px;' + LineEnding +
                      '  }' + LineEnding +
                      '  .kanban-list-title {' + LineEnding +
                      '    cursor: move;' + LineEnding +
                      '  }' + LineEnding +
                      '</style>' + LineEnding +
                      '<section id="kanban-board" aria-label="Kanban Board" role="region" tabindex="0">' + LineEnding +
                      '  <h1>Accessible Kanban Board</h1>' + LineEnding +
                      '  <div class="swimlane" role="region" aria-label="Swimlane 1" tabindex="0" draggable="true">' + LineEnding +
                      '    <h2>Swimlane 1</h2>' + LineEnding +
                      '    <div class="kanban-lists-container">' + LineEnding +
                      '      <div class="kanban-list" role="list" aria-label="List 1" tabindex="0">' + LineEnding +
                      '        <h3 class="kanban-list-title" draggable="true">List 1</h3>' + LineEnding +
                      '        <div class="kanban-card" role="listitem" tabindex="0">Card 1</div>' + LineEnding +
                      '        <div class="kanban-card" role="listitem" tabindex="0">Card 2</div>' + LineEnding +
                      '      </div>' + LineEnding +
                      '      <div class="kanban-list" role="list" aria-label="List 2" tabindex="0">' + LineEnding +
                      '        <h3 class="kanban-list-title" draggable="true">List 2</h3>' + LineEnding +
                      '        <div class="kanban-card" role="listitem" tabindex="0">Card A</div>' + LineEnding +
                      '        <div class="kanban-card" role="listitem" tabindex="0">Card B</div>' + LineEnding +
                      '      </div>' + LineEnding +
                      '    </div>' + LineEnding +
                      '  </div>' + LineEnding +
                      '  <div class="swimlane" role="region" aria-label="Swimlane 2" tabindex="0" draggable="true">' + LineEnding +
                      '    <h2>Swimlane 2</h2>' + LineEnding +
                      '    <div class="kanban-lists-container">' + LineEnding +
                      '      <div class="kanban-list" role="list" aria-label="List 3" tabindex="0">' + LineEnding +
                      '        <h3 class="kanban-list-title" draggable="true">List 3</h3>' + LineEnding +
                      '        <div class="kanban-card" role="listitem" tabindex="0">Card 3</div>' + LineEnding +
                      '        <div class="kanban-card" role="listitem" tabindex="0">Card 4</div>' + LineEnding +
                      '      </div>' + LineEnding +
                      '      <div class="kanban-list" role="list" aria-label="List 4" tabindex="0">' + LineEnding +
                      '        <h3 class="kanban-list-title" draggable="true">List 4</h3>' + LineEnding +
                      '        <div class="kanban-card" role="listitem" tabindex="0">Card C</div>' + LineEnding +
                      '        <div class="kanban-card" role="listitem" tabindex="0">Card D</div>' + LineEnding +
                      '      </div>' + LineEnding +
                      '    </div>' + LineEnding +
                      '  </div>' + LineEnding +
                      '  <script>' + LineEnding +
                      '    let selectedElement = null;' + LineEnding +
                      '    let isMoving = false;' + LineEnding +
                      '    let sourceList = null;' + LineEnding +
                      '    let placeholder = null;' + LineEnding +
                      '    let swimlanePlaceholder = null;' + LineEnding +
                      '' + LineEnding +
                      '    function handleSelection(e) {' + LineEnding +
                      '      const card = e.target.closest(".kanban-card"' + LineEnding +
                      '      if (!card) return;' + LineEnding +
                      '' + LineEnding +
                      '      if (e.key === " ") {' + LineEnding +
                      '        e.preventDefault(' + LineEnding +
                      '        if (!isMoving) {' + LineEnding +
                      '          if (selectedElement) {' + LineEnding +
                      '            selectedElement.classList.remove("selected"' + LineEnding +
                      '          }' + LineEnding +
                      '          selectedElement = card;' + LineEnding +
                      '          sourceList = card.closest(".kanban-list"' + LineEnding +
                      '          selectedElement.classList.add("selected", "moving"' + LineEnding +
                      '          selectedElement.setAttribute("aria-grabbed", "true"' + LineEnding +
                      '          isMoving = true;' + LineEnding +
                      '          placeholder = document.createElement("div"' + LineEnding +
                      '          placeholder.className = "card-placeholder";' + LineEnding +
                      '          card.parentNode.insertBefore(placeholder, card.nextSibling' + LineEnding +
                      '        } else {' + LineEnding +
                      '          completeMove(' + LineEnding +
                      '        }' + LineEnding +
                      '      }' + LineEnding +
                      '    }' + LineEnding +
                      '' + LineEnding +
                      '    function completeMove() {' + LineEnding +
                      '      if (!selectedElement) return;' + LineEnding +
                      '' + LineEnding +
                      '      selectedElement.classList.remove("moving", "selected"' + LineEnding +
                      '      selectedElement.setAttribute("aria-grabbed", "false"' + LineEnding +
                      '      const targetList = document.activeElement.closest(".kanban-list"' + LineEnding +
                      '      if (targetList) {' + LineEnding +
                      '        targetList.insertBefore(selectedElement, placeholder' + LineEnding +
                      '        announceMove(sourceList, targetList' + LineEnding +
                      '      }' + LineEnding +
                      '      placeholder.remove(' + LineEnding +
                      '      isMoving = false;' + LineEnding +
                      '      sourceList = null;' + LineEnding +
                      '      placeholder = null;' + LineEnding +
                      '    }' + LineEnding +
                      '' + LineEnding +
                      '    function announceMove(from, to) {' + LineEnding +
                      '      const announcement = document.createElement("div"' + LineEnding +
                      '      announcement.setAttribute("role", "alert"' + LineEnding +
                      '      announcement.setAttribute("aria-live", "polite"' + LineEnding +
                      '      announcement.textContent = `Card moved from ${from.querySelector("h3").textContent} to ${to.querySelector("h3").textContent}`;' + LineEnding +
                      '      document.body.appendChild(announcement' + LineEnding +
                      '      setTimeout(() => announcement.remove(), 1000' + LineEnding +
                      '    }' + LineEnding +
                      '' + LineEnding +
                      '    document.addEventListener("keydown", function(e) {' + LineEnding +
                      '      if (e.key === " ") {' + LineEnding +
                      '        handleSelection(e' + LineEnding +
                      '      }' + LineEnding +
                      '      ' + LineEnding +
                      '      if (isMoving) {' + LineEnding +
                      '        const lists = Array.from(document.querySelectorAll(".kanban-list")' + LineEnding +
                      '        const currentList = document.activeElement.closest(".kanban-list"' + LineEnding +
                      '        const currentIndex = lists.indexOf(currentList' + LineEnding +
                      '' + LineEnding +
                      '        switch(e.key) {' + LineEnding +
                      '          case "ArrowLeft":' + LineEnding +
                      '            e.preventDefault(' + LineEnding +
                      '            if (currentIndex > 0) {' + LineEnding +
                      '              lists[currentIndex - 1].focus(' + LineEnding +
                      '            }' + LineEnding +
                      '            break;' + LineEnding +
                      '          case "ArrowRight":' + LineEnding +
                      '            e.preventDefault(' + LineEnding +
                      '            if (currentIndex < lists.length - 1) {' + LineEnding +
                      '              lists[currentIndex + 1].focus(' + LineEnding +
                      '            }' + LineEnding +
                      '            break;' + LineEnding +
                      '          case "ArrowUp":' + LineEnding +
                      '            e.preventDefault(' + LineEnding +
                      '            if (selectedElement.previousElementSibling && selectedElement.previousElementSibling !== placeholder) {' + LineEnding +
                      '              selectedElement.parentNode.insertBefore(placeholder, selectedElement.previousElementSibling' + LineEnding +
                      '            }' + LineEnding +
                      '            break;' + LineEnding +
                      '          case "ArrowDown":' + LineEnding +
                      '            e.preventDefault(' + LineEnding +
                      '            if (selectedElement.nextElementSibling) {' + LineEnding +
                      '              selectedElement.parentNode.insertBefore(placeholder, selectedElement.nextElementSibling.nextSibling' + LineEnding +
                      '            }' + LineEnding +
                      '            break;' + LineEnding +
                      '          case "Escape":' + LineEnding +
                      '            e.preventDefault(' + LineEnding +
                      '            selectedElement.classList.remove("moving", "selected"' + LineEnding +
                      '            selectedElement.setAttribute("aria-grabbed", "false"' + LineEnding +
                      '            placeholder.remove(' + LineEnding +
                      '            isMoving = false;' + LineEnding +
                      '            break;' + LineEnding +
                      '        }' + LineEnding +
                      '      }' + LineEnding +
                      '    }' + LineEnding +
                      '' + LineEnding +
                      '    document.querySelectorAll(".kanban-card").forEach(card => {' + LineEnding +
                      '      card.setAttribute("draggable", "true"' + LineEnding +
                      '      card.addEventListener("dragstart", function(e) {' + LineEnding +
                      '        selectedElement = e.target;' + LineEnding +
                      '        sourceList = selectedElement.closest(".kanban-list"' + LineEnding +
                      '        e.dataTransfer.effectAllowed = "move";' + LineEnding +
                      '        setTimeout(() => selectedElement.classList.add("moving"), 0' + LineEnding +
                      '      }' + LineEnding +
                      '      card.addEventListener("dragend", function() {' + LineEnding +
                      '        selectedElement.classList.remove("moving"' + LineEnding +
                      '        selectedElement = null;' + LineEnding +
                      '        sourceList = null;' + LineEnding +
                      '      }' + LineEnding +
                      '    }' + LineEnding +
                      '' + LineEnding +
                      '    document.querySelectorAll(".kanban-list").forEach(list => {' + LineEnding +
                      '      list.addEventListener("dragover", function(e) {' + LineEnding +
                      '        e.preventDefault(' + LineEnding +
                      '        e.dataTransfer.dropEffect = "move";' + LineEnding +
                      '        const afterElement = getDragAfterElement(list, e.clientY' + LineEnding +
                      '        if (afterElement == null) {' + LineEnding +
                      '          list.appendChild(placeholder' + LineEnding +
                      '        } else {' + LineEnding +
                      '          list.insertBefore(placeholder, afterElement' + LineEnding +
                      '        }' + LineEnding +
                      '      }' + LineEnding +
                      '      list.addEventListener("drop", function(e) {' + LineEnding +
                      '        e.preventDefault(' + LineEnding +
                      '        if (selectedElement) {' + LineEnding +
                      '          list.insertBefore(selectedElement, placeholder' + LineEnding +
                      '          announceMove(sourceList, list' + LineEnding +
                      '        }' + LineEnding +
                      '        placeholder.remove(' + LineEnding +
                      '      }' + LineEnding +
                      '    }' + LineEnding +
                      '' + LineEnding +
                      '    document.querySelectorAll(".swimlane").forEach(swimlane => {' + LineEnding +
                      '      swimlane.addEventListener("dragstart", function(e) {' + LineEnding +
                      '        selectedElement = e.target;' + LineEnding +
                      '        e.dataTransfer.effectAllowed = "move";' + LineEnding +
                      '        setTimeout(() => selectedElement.classList.add("moving"), 0' + LineEnding +
                      '      }' + LineEnding +
                      '      swimlane.addEventListener("dragend", function() {' + LineEnding +
                      '        selectedElement.classList.remove("moving"' + LineEnding +
                      '        selectedElement = null;' + LineEnding +
                      '      }' + LineEnding +
                      '      swimlane.addEventListener("dragover", function(e) {' + LineEnding +
                      '        e.preventDefault(' + LineEnding +
                      '        e.dataTransfer.dropEffect = "move";' + LineEnding +
                      '        const afterElement = getDragAfterElement(swimlane.parentNode, e.clientY' + LineEnding +
                      '        if (afterElement == null) {' + LineEnding +
                      '          swimlane.parentNode.appendChild(swimlanePlaceholder' + LineEnding +
                      '        } else {' + LineEnding +
                      '          swimlane.parentNode.insertBefore(swimlanePlaceholder, afterElement' + LineEnding +
                      '        }' + LineEnding +
                      '      }' + LineEnding +
                      '      swimlane.addEventListener("drop", function(e) {' + LineEnding +
                      '        e.preventDefault(' + LineEnding +
                      '        if (selectedElement) {' + LineEnding +
                      '          swimlane.parentNode.insertBefore(selectedElement, swimlanePlaceholder' + LineEnding +
                      '        }' + LineEnding +
                      '        swimlanePlaceholder.remove(' + LineEnding +
                      '      }' + LineEnding +
                      '    }' + LineEnding +
                      '' + LineEnding +
                      '    document.querySelectorAll(".kanban-list-title").forEach(title => {' + LineEnding +
                      '      title.addEventListener("dragstart", function(e) {' + LineEnding +
                      '        selectedElement = e.target.closest(".kanban-list"' + LineEnding +
                      '        e.dataTransfer.effectAllowed = "move";' + LineEnding +
                      '        setTimeout(() => selectedElement.classList.add("moving"), 0' + LineEnding +
                      '      }' + LineEnding +
                      '      title.addEventListener("dragend", function() {' + LineEnding +
                      '        selectedElement.classList.remove("moving"' + LineEnding +
                      '        selectedElement = null;' + LineEnding +
                      '      }' + LineEnding +
                      '    }' + LineEnding +
                      '' + LineEnding +
                      '    function getDragAfterElement(container, y) {' + LineEnding +
                      '      const draggableElements = [...container.querySelectorAll(".swimlane:not(.moving)")];' + LineEnding +
                      '' + LineEnding +
                      '      return draggableElements.reduce((closest, child) => {' + LineEnding +
                      '        const box = child.getBoundingClientRect(' + LineEnding +
                      '        const offset = y - box.top - box.height / 2;' + LineEnding +
                      '        if (offset < 0 && offset > closest.offset) {' + LineEnding +
                      '          return { offset: offset, element: child };' + LineEnding +
                      '        } else {' + LineEnding +
                      '          return closest;' + LineEnding +
                      '        }' + LineEnding +
                      '      }, { offset: Number.NEGATIVE_INFINITY }).element;' + LineEnding +
                      '    }' + LineEnding +
                      '  </script>' + LineEnding +
                      '</section>' + LineEnding +

                      '<table border="0" padding="0" spacing="0" width="100%">' + LineEnding +
                      '  <tbody>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td width="20" height="20"></td>' + LineEnding +
                      '      <td width="200" height="80" valign="middle" align="left">' + LineEnding +
                      '        <font size="4" color="white" face="arial"><b>To Do</b></font>' + LineEnding +
                      '      </td>' + LineEnding +
                      '      <td width="200" height="80" valign="middle" align="left">' + LineEnding +
                      '        <font size="4" color="white" face="arial"><b>In Progress</b></font>' + LineEnding +
                      '      </td>' + LineEnding +
                      '      <td width="200" height="80" valign="middle" align="left">' + LineEnding +
                      '        <font size="4" color="white" face="arial"><b>Done</b></font>' + LineEnding +
                      '      </td>' + LineEnding +
                      '      <td width="20" height="20"></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '  </tbody>' + LineEnding +
                      '</table>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure cardEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Card - WeKan</title></head><body>' + LineEnding +
                      '<h1>Card Details</h1>' + LineEnding +
                      '<table border="0" padding="0" spacing="0" width="100%">' + LineEnding +
                      '  <tbody>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td width="20" height="20"></td>' + LineEnding +
                      '      <td width="400" height="80" valign="middle" align="left">' + LineEnding +
                      '        <font size="4" color="black" face="arial"><b>Sample Task</b></font>' + LineEnding +
                      '        <br><font size="2" color="gray" face="arial">Description: This is a sample task description</font>' + LineEnding +
                      '      </td>' + LineEnding +
                      '      <td width="20" height="20"></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '  </tbody>' + LineEnding +
                      '</table>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure shortcutsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Shortcuts - WeKan</title></head><body>' + LineEnding +
                      '<h1>Shortcuts</h1>' + LineEnding +
                      '<p>Keyboard shortcuts and quick access will be implemented here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure calendarEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  // This calendar has been tested to be visible at: Amiga IBrowse, FreeDOS Dillo, Linux Dillo/Netsurf/Chrome
  //
  // For accessibility, use only one table. Not nested table. Avoid merged or split cells.
  // Consider Alternative Views: For calendars, offer a "list view" or other simplified
  // representations that are inherently more linear and accessible for assistive technology users.
  //

  // background-color: #d1e7dd; Light green to highlight today

  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">' + LineEnding +
                      '<html lang="en">' + LineEnding +
                      '<head>' + LineEnding +
                      '  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">' + LineEnding +
                      '  <title>July 2025 Calendar</title>' + LineEnding +
                      '  <style type="text/css">' + LineEnding +
                      '    table      { width: 100%; border-collapse: collapse; margin-bottom: 20px; }' + LineEnding +
                      '    th, td     { border: 1px solid #ccc; padding: 8px; text-align: center; }' + LineEnding +
                      '    th         { background-color: #f2f2f2; }' + LineEnding +
                      '    .empty-day { background-color: #eee; color: #999; }' + LineEnding +
                      '    .today     { background-color: #d1e7dd; font-weight: bold; border: 2px solid #007bff; }' + LineEnding +
                      '    caption    { font-size: 1.5em; margin-bottom: 10px; font-weight: bold; text-align: left; }' + LineEnding +
                      '  </style>' + LineEnding +
                      '</head>' + LineEnding +
                      '<body bgcolor="#FFFFFF">' + LineEnding +
                      '<p><a href="../">All Pages</a></p>' + LineEnding +
                      '<h1><font face="arial">July 2025</font></h1>' + LineEnding +
                      '<table summary="This table displays the calendar. Days of the week are column headers, and dates are listed under them." width="100%" border-collapse="collapse" margin-bottom="20" border="1" cellpadding="5" cellspacing="0" id="calendartable">' + LineEnding +
                      '  <caption><font size="4" face="arial">July 2025</font></caption>' + LineEnding +
                      '  <thead>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <th scope="col" border="1" padding="8" align="center" bgcolor="#f2f2f2"><font size="4" face="arial">Monday</font></th>' + LineEnding +
                      '      <th scope="col" border="1" padding="8" align="center" bgcolor="#f2f2f2"><font size="4" face="arial">Tuesday</font></th>' + LineEnding +
                      '      <th scope="col" border="1" padding="8" align="center" bgcolor="#f2f2f2"><font size="4" face="arial">Wednesday</font></th>' + LineEnding +
                      '      <th scope="col" border="1" padding="8" align="center" bgcolor="#f2f2f2"><font size="4" face="arial">Thursday</font></th>' + LineEnding +
                      '      <th scope="col" border="1" padding="8" align="center" bgcolor="#f2f2f2"><font size="4" face="arial">Friday</font></th>' + LineEnding +
                      '      <th scope="col" border="1" padding="8" align="center" bgcolor="#f2f2f2"><font size="4" face="arial">Saturday</font></th>' + LineEnding +
                      '      <th scope="col" border="1" padding="8" align="center" bgcolor="#f2f2f2"><font size="4" face="arial">Sunday</font></th>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '  </thead>' + LineEnding +
                      '  <tbody>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td class="empty-day" border="1" padding="8" align="center" color="#999999" bgcolor="#eeeeee"><font size="4" face="arial"></font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">1</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">2</font></td>' + LineEnding +
                      '      <td class="today" border="3" padding="8" align="center" bgcolor="#d1e7dd" border="2"><b><font size="4" face="arial">3</font></b></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">4</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">5</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">6</font></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">7</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">8</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">9</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">10</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">11</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">12</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">13</font></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">14</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">15</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">16</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">17</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">18</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">19</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">20</font></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">21</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">22</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">23</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">24</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">25</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">26</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">27</font></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '    <tr>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">28</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">29</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">30</font></td>' + LineEnding +
                      '      <td border="1" padding="8" align="center"><font size="4" face="arial">31</font></td>' + LineEnding +
                      '      <td class="empty-day" border="1" padding="8" align="center" color="#999999" bgcolor="#eeeeee"><font size="4" face="arial"></font></td>' + LineEnding +
                      '      <td class="empty-day" border="1" padding="8" align="center" color="#999999" bgcolor="#eeeeee"><font size="4" face="arial"></font></td>' + LineEnding +
                      '      <td class="empty-day" border="1" padding="8" align="center" color="#999999" bgcolor="#eeeeee"><font size="4" face="arial"></font></td>' + LineEnding +
                      '    </tr>' + LineEnding +
                      '  </tbody>' + LineEnding +
                      '</table>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure templatesEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Templates - WeKan</title></head><body>' + LineEnding +
                      '<h1>Board Templates</h1>' + LineEnding +
                      '<p>Pre-defined board templates will be displayed here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure myCardsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>My Cards - WeKan</title></head><body>' + LineEnding +
                      '<h1>My Cards</h1>' + LineEnding +
                      '<p>Cards assigned to you will be displayed here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure dueCardsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Due Cards - WeKan</title></head><body>' + LineEnding +
                      '<h1>Due Cards</h1>' + LineEnding +
                      '<p>Cards with upcoming due dates will be displayed here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure globalSearchEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Global Search - WeKan</title></head><body>' + LineEnding +
                      '<h1>Global Search</h1>' + LineEnding +
                      '<form action="search" method="GET">' + LineEnding +
                      '  <input type="text" name="q" size="50" placeholder="Search for cards, boards, users...">' + LineEnding +
                      '  <input type="submit" value="Search">' + LineEnding +
                      '</form>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure brokenCardsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Broken Cards - WeKan</title></head><body>' + LineEnding +
                      '<h1>Broken Cards</h1>' + LineEnding +
                      '<p>Cards with issues will be displayed here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure accessibilityEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Accessibility - WeKan</title></head><body>' + LineEnding +
                      '<h1>Accessibility Features</h1>' + LineEnding +
                      '<p>WeKan is designed to be accessible to all users, including those using screen readers and assistive technologies.</p>' + LineEnding +
                      '<h2>Keyboard Navigation</h2>' + LineEnding +
                      '<ul>' + LineEnding +
                      '  <li>Use Tab key to navigate between elements</li>' + LineEnding +
                      '  <li>Use Enter or Space to activate buttons and links</li>' + LineEnding +
                      '  <li>Use Arrow keys to navigate within lists and cards</li>' + LineEnding +
                      '</ul>' + LineEnding +
                      '<h2>Screen Reader Support</h2>' + LineEnding +
                      '<ul>' + LineEnding +
                      '  <li>All images have descriptive alt text</li>' + LineEnding +
                      '  <li>Proper heading structure for navigation</li>' + LineEnding +
                      '  <li>Semantic HTML elements for better understanding</li>' + LineEnding +
                      '</ul>' + LineEnding +
                      '<h2>High Contrast</h2>' + LineEnding +
                      '<p>WeKan supports high contrast modes and can be used with browser accessibility features.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure importEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Import - WeKan</title></head><body>' + LineEnding +
                      '<h1>Import Data</h1>' + LineEnding +
                      '<p>Import data from other sources will be implemented here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure adminSettingEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Admin Settings - WeKan</title></head><body>' + LineEnding +
                      '<h1>Admin Settings</h1>' + LineEnding +
                      '<p>Administrative settings will be implemented here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure informationEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Information - WeKan</title></head><body>' + LineEnding +
                      '<h1>System Information</h1>' + LineEnding +
                      '<p>System information and status will be displayed here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure peopleEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>People - WeKan</title></head><body>' + LineEnding +
                      '<h1>People Management</h1>' + LineEnding +
                      '<p>User management interface will be implemented here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure adminReportsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Admin Reports - WeKan</title></head><body>' + LineEnding +
                      '<h1>Admin Reports</h1>' + LineEnding +
                      '<p>Administrative reports will be implemented here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure translationEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Translation - WeKan</title></head><body>' + LineEnding +
                      '<h1>Translation</h1>' + LineEnding +
                      '<p>Translation management interface will be implemented here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure jsonEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '{"status": "ok", "message": "JSON API endpoint"}';
  aResponse.Code := 200;
  aResponse.ContentType := 'application/json';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure attachmentsEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Attachments - WeKan</title></head><body>' + LineEnding +
                      '<h1>Attachments Management</h1>' + LineEnding +
                      '<p>File attachments management interface will be implemented here.</p>' + LineEnding +
                      '<p><a href=".">Back to Home</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

procedure serveStaticFileEndpoint(aRequest: TRequest; aResponse: TResponse);
var
  FilePath: String;
  FileStream: TFileStream;
  FileExt: String;
  MimeType: String;
  IndexPath: String;
  RequestPath: String;
  FullPublicPath: String;
  NormalizedFilePath: String;
begin
  // Security: Check for directory traversal attempts
  RequestPath := aRequest.PathInfo;
  if (Pos('..', RequestPath) > 0) or (Pos('/./', RequestPath) > 0) then
  begin
    aResponse.Code := 403;
    aResponse.Content := 'Access denied: Invalid path';
    aResponse.ContentType := 'text/plain';
    aResponse.SendContent;
    Exit;
  end;
  // Get absolute path to public directory for security checks
  FullPublicPath := ExpandFileName('public');
  // Construct path to requested file in public directory
  FilePath := 'public' + RequestPath;
  // If the path ends with a directory separator, append 'index.html'
  if (Length(FilePath) > 0) and (FilePath[Length(FilePath)] = DirectorySeparator) then
    FilePath := FilePath + 'index.html'
  // Check if the path is a directory, and if so, look for index.html
  else if DirectoryExists(FilePath) then
  begin
    IndexPath := IncludeTrailingPathDelimiter(FilePath) + 'index.html';
    if FileExists(IndexPath) then
      FilePath := IndexPath;
  end;
  // Security: Ensure the file is within the public directory
  NormalizedFilePath := ExpandFileName(FilePath);
  if (Copy(NormalizedFilePath, 1, Length(FullPublicPath)) <> FullPublicPath) then
  begin
    aResponse.Code := 403;
    aResponse.Content := 'Access denied: Path outside public directory';
    aResponse.ContentType := 'text/plain';
    aResponse.SendContent;
    Exit;
  end;
  // Check if file exists
  if not FileExists(NormalizedFilePath) then
  begin
    // If file doesn't exist, let the catchall handle it
    aResponse.Code := 404;
    aResponse.Content := 'File not found: ' + aRequest.PathInfo;
    aResponse.ContentType := 'text/plain';
    aResponse.SendContent;
    Exit;
  end;
  try
    // Determine content type based on file extension
    FileExt := LowerCase(ExtractFileExt(NormalizedFilePath));
    MimeType := 'application/octet-stream'; // Default MIME type
    if FileExt = '.html' then
      MimeType := 'text/html'
    else if FileExt = '.css' then
      MimeType := 'text/css'
    else if FileExt = '.js' then
      MimeType := 'application/javascript'
    else if FileExt = '.json' then
      MimeType := 'application/json'
    else if FileExt = '.png' then
      MimeType := 'image/png'
    else if FileExt = '.jpg' then
      MimeType := 'image/jpeg'
    else if FileExt = '.gif' then
      MimeType := 'image/gif'
    else if FileExt = '.svg' then
      MimeType := 'image/svg+xml'
    else if FileExt = '.ico' then
      MimeType := 'image/x-icon'
    else if FileExt = '.txt' then
      MimeType := 'text/plain';
    // Open file and send its contents
    FileStream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyWrite);
    try
      aResponse.ContentStream := FileStream;
      aResponse.ContentType := MimeType;
      aResponse.FreeContentStream := True; // Let TResponse free the stream
      aResponse.SendContent;
    except
      on E: Exception do
      begin
        FileStream.Free;
        aResponse.Code := 500;
        aResponse.Content := 'Error serving file: ' + E.Message;
        aResponse.ContentType := 'text/plain';
        aResponse.SendContent;
      end;
    end;
  except
    on E: Exception do
    begin
      aResponse.Code := 500;
      aResponse.Content := 'Error: ' + E.Message;
      aResponse.ContentType := 'text/plain';
      aResponse.SendContent;
    end;
  end;
end;

procedure logoutEndpoint(aRequest: TRequest; aResponse: TResponse);
begin
  // Clear current user session
  CurrentUser := '';
  aResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">' + LineEnding +
                      '<html><head><title>Logged Out - WeKan</title>' + LineEnding +
                      '<meta http-equiv="refresh" content="2;url=.">' + LineEnding +
                      '</head><body>' + LineEnding +
                      '<h1>Logged Out</h1>' + LineEnding +
                      '<p>You have been successfully logged out.</p>' + LineEnding +
                      '<p>You will be redirected to the home page in 2 seconds...</p>' + LineEnding +
                      '<p><a href=".">Click here if you are not redirected automatically</a></p>' + LineEnding +
                      '</body></html>';
  aResponse.Code := 200;
  aResponse.ContentType := 'text/html';
  aResponse.ContentLength := Length(aResponse.Content);
  aResponse.SendContent;
end;

// We maintain a list of redirections to ensure that we don't break old URLs
// when we change our routing scheme.
//-- const redirections = {
//--   '/boards': '/',
//--   '/boards/:id/:slug': '/b/:id/:slug',
//--   '/boards/:id/:slug/:cardId': '/b/:id/:slug/:cardId',
//--  '/import': '/import/trello',
//--};
//--        redirect(FlowRouter.path(newPath, context.params));
//-- set static assets
//fm.setRoute("/*", "/assets/*")

begin
  Application.Port:=5500;
  // Initialize random number generator
  Randomize;
  // Initialize SQLite database
  if not InitializeUserStorage then
  begin
    Writeln('Failed to initialize user storage. Exiting.');
    Exit;
  end;
  
  // Main routes matching router.js structure
  HTTPRouter.RegisterRoute('/', rmGet, @allPagesEndpoint);
  
  // Authentication routes
  HTTPRouter.RegisterRoute('/sign-in', rmGet, @loginEndpoint);
  HTTPRouter.RegisterRoute('/sign-in', rmPost, @loginEndpoint);
  HTTPRouter.RegisterRoute('/sign-up', rmGet, @registerEndpoint);
  HTTPRouter.RegisterRoute('/sign-up', rmPost, @registerEndpoint);
  HTTPRouter.RegisterRoute('/forgot-password', rmGet, @forgotPasswordEndpoint);
  HTTPRouter.RegisterRoute('/forgot-password', rmPost, @forgotPasswordEndpoint);
  HTTPRouter.RegisterRoute('/logout', rmGet, @logoutEndpoint); // Add logout endpoint
  
  // Board routes
  HTTPRouter.RegisterRoute('/allboards', rmGet, @allBoardsEndpoint);
  HTTPRouter.RegisterRoute('/public', rmGet, @publicEndpoint);
  HTTPRouter.RegisterRoute('/board', rmGet, @boardEndpoint);
  HTTPRouter.RegisterRoute('/b/:id/:slug', rmGet, @boardEndpoint); // Board with ID and slug
  HTTPRouter.RegisterRoute('/b/:boardId/:slug/:cardId', rmGet, @cardEndpoint); // Card within board
  
  // Card routes
  HTTPRouter.RegisterRoute('/card', rmGet, @cardEndpoint);
  HTTPRouter.RegisterRoute('/my-cards', rmGet, @myCardsEndpoint);
  HTTPRouter.RegisterRoute('/due-cards', rmGet, @dueCardsEndpoint);
  
  // Utility routes
  HTTPRouter.RegisterRoute('/shortcuts', rmGet, @shortcutsEndpoint);
  HTTPRouter.RegisterRoute('/templates', rmGet, @templatesEndpoint);
  HTTPRouter.RegisterRoute('/b/templates', rmGet, @templatesEndpoint); // Template container
  HTTPRouter.RegisterRoute('/accessibility', rmGet, @accessibilityEndpoint);
  
  // Search and import
  HTTPRouter.RegisterRoute('/global-search', rmGet, @globalSearchEndpoint);
  HTTPRouter.RegisterRoute('/import', rmGet, @importEndpoint);
  HTTPRouter.RegisterRoute('/import/:source', rmGet, @importEndpoint); // Import with source
  
  // Admin and settings routes
  HTTPRouter.RegisterRoute('/setting', rmGet, @adminSettingEndpoint);
  HTTPRouter.RegisterRoute('/information', rmGet, @informationEndpoint);
  HTTPRouter.RegisterRoute('/people', rmGet, @peopleEndpoint);
  HTTPRouter.RegisterRoute('/admin-reports', rmGet, @adminReportsEndpoint);
  HTTPRouter.RegisterRoute('/attachments', rmGet, @attachmentsEndpoint);
  HTTPRouter.RegisterRoute('/translation', rmGet, @translationEndpoint);
  HTTPRouter.RegisterRoute('/broken-cards', rmGet, @brokenCardsEndpoint);
  
  // User routes
  HTTPRouter.RegisterRoute('/usersettings', rmGet, @userSettingsEndpoint);
  HTTPRouter.RegisterRoute('/notifications', rmGet, @notificationsEndpoint);
  
  // Calendar and other features
  HTTPRouter.RegisterRoute('/calendar', rmGet, @calendarEndpoint);
  
  // Upload functionality
  HTTPRouter.RegisterRoute('/upload', rmGet, @uploadEndpoint);
  HTTPRouter.RegisterRoute('/upload', rmPost, @uploadEndpoint);
  
  // API routes
  HTTPRouter.RegisterRoute('/json', rmGet, @jsonEndpoint);
  HTTPRouter.RegisterRoute('/screeninfo', rmPost, @screenInfoEndpoint);
  
  // Legacy redirects (matching router.js redirections)
  HTTPRouter.RegisterRoute('/boards', rmGet, @allBoardsEndpoint);
  HTTPRouter.RegisterRoute('/boards/:id/:slug', rmGet, @boardEndpoint);
  HTTPRouter.RegisterRoute('/boards/:id/:slug/:cardId', rmGet, @cardEndpoint);
  
  // Add static file server for files in the public directory
  // This route should come before the catchall
  HTTPRouter.RegisterRoute('/*', rmGet, @serveStaticFileEndpoint);
  
  // Fallback for any remaining requests
  HTTPRouter.RegisterRoute('/catchall', rmAll, @catchallEndpoint, true);
  
  // Create public directory if it doesn't exist
  if not DirectoryExists('public') then
    CreateDir('public');
    
  Application.Threaded:=false;
  Application.Initialize;
  Writeln('Server is ready at localhost:' + IntToStr(Application.Port));
  Writeln('Static files are served from the public/ directory');
  Writeln('User storage initialized successfully');
  Application.Run;
end.
