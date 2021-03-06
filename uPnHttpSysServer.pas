unit uPnHttpSysServer;

interface

uses
  System.SysUtils,
  SynCommons,
  System.Classes,
  Winapi.Windows,
  uPnHttpSys.Api,
  uPnHttpSys.Comm,
  uPNObject,
  uPNObjectPool;

const
  // space for Req^ + 16 KB of headers
  BUFFERLEN = 16*1024 + SizeOf(HTTP_REQUEST);

type
  TPnHttpServerContext = class;

  THttpIoAction = (
    IoNone,
    IoRequestHead,
    IoRequestBody,
    IoResponseBody,
    IoResponseEnd
  );

  PPerHttpIoData = ^TPerHttpIoData;
  TPerHttpIoData = record
    Overlapped: TOverlapped;
    IoData: TPnHttpServerContext;
    //ReqBuffer: array [0..BUFFERLEN-1] of AnsiChar;
    //Buffer: Pointer;
    BytesRead: Cardinal;
    Action: THttpIoAction;
    hFile: THandle;
  end;

  TPnHttpSysServer = class;

  /// http.sys API 2.0 fields used for server-side authentication
  // - as used by THttpApiServer.SetAuthenticationSchemes/AuthenticationSchemes
  // - match low-level HTTP_AUTH_ENABLE_* constants as defined in HTTP 2.0 API
  THttpApiRequestAuthentications = set of (
    haBasic, haDigest, haNtlm, haNegotiate, haKerberos);

  /// the server-side available authentication schemes
  // - as used by THttpServerRequest.AuthenticationStatus
  // - hraNone..hraKerberos will match low-level HTTP_REQUEST_AUTH_TYPE enum as
  // defined in HTTP 2.0 API and
  THttpServerRequestAuthentication = (
    hraNone, hraFailed, hraBasic, hraDigest, hraNtlm, hraNegotiate, hraKerberos);


  TPnHttpServerContext = class(TPNObject)
  private
    fServer: TPnHttpSysServer;
    //async_req
    fReqPerHttpIoData: PPerHttpIoData;

    //fReqBuf: array [0..BUFFERLEN-1] of AnsiChar;
    fReqBuf: SockString;
    fReqBufLen: Cardinal;
    fReq: PHTTP_REQUEST;
    fAuthenticationSchemes: THttpApiRequestAuthentications;

    fURL, fMethod, fInHeaders, fInContent, fInContentType: SockString;
    fInContentBufRead: PAnsiChar;
    fRemoteIPHeader, fRemoteIPHeaderUpper: SockString;
    fRemoteIP: SockString;


    fInContentLength, fInContentLengthChunk, fInContentLengthRead: Cardinal;
    fInContentEncoding, fInAcceptEncoding, fRange: SockString;

    fResp: HTTP_RESPONSE;
    fOutContent, fOutContentType, fOutCustomHeaders: SockString;
    fOutStatusCode: Cardinal;
    fConnectionID: Int64;
    fUseSSL: Boolean;
    fAuthenticationStatus: THttpServerRequestAuthentication;
    fAuthenticatedUser: SockString;

    fInCompressAccept: THttpSocketCompressSet;

    fRespSent: Boolean;

    function _NewIoData: PPerHttpIoData; //inline;
    procedure _FreeIoData(P: PPerHttpIoData); //inline;
  public
    constructor Create(AServer: TPnHttpSysServer); //virtual;
    destructor Destroy; override;
    procedure InitObject; override;
    procedure SetHeaders(Resp: PHTTP_RESPONSE; P: PAnsiChar; var UnknownHeaders: HTTP_UNKNOWN_HEADERs); //inline;
    function AddCustomHeader(Resp: PHTTP_RESPONSE; P: PAnsiChar; var UnknownHeaders: HTTP_UNKNOWN_HEADERs;
      ForceCustomHeader: boolean): PAnsiChar;
    procedure SendError(StatusCode: Cardinal; const ErrorMsg: string; E: Exception = nil);
    function SendResponse: Boolean;


    /// input parameter containing the caller URI
    property URL: SockString read fURL;
    /// input parameter containing the caller method (GET/POST...)
    property Method: SockString read fMethod;
    /// input parameter containing the caller message headers
    property InHeaders: SockString read fInHeaders;
    /// input parameter containing the caller message body
    // - e.g. some GET/POST/PUT JSON data can be specified here
    property InContent: SockString read fInContent;
    // input parameter defining the caller message body content type
    property InContentType: SockString read fInContentType;
    /// output parameter to be set to the response message body
    property OutContent: SockString read fOutContent write fOutContent ;
    /// output parameter to define the reponse message body content type
    // - if OutContentType is HTTP_RESP_STATICFILE (i.e. '!STATICFILE', defined
    // as STATICFILE_CONTENT_TYPE in mORMot.pas), then OutContent is the UTF-8
    // file name of a file which must be sent to the client via http.sys (much
    // faster than manual buffering/sending)
    // - if OutContentType is HTTP_RESP_NORESPONSE (i.e. '!NORESPONSE', defined
    // as NORESPONSE_CONTENT_TYPE in mORMot.pas), then the actual transmission
    // protocol may not wait for any answer - used e.g. for WebSockets
    property OutContentType: SockString read fOutContentType write fOutContentType;
    /// output parameter to be sent back as the response message header
    // - e.g. to set Content-Type/Location
    property OutCustomHeaders: SockString read fOutCustomHeaders write fOutCustomHeaders;

  end;


  TIoEventThread = class(TThread)
  private
    FServer: TPnHttpSysServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TPnHttpSysServer); reintroduce;
  end;


  /// event handler used by THttpServerGeneric.OnRequest property
  // - Ctxt defines both input and output parameters
  // - result of the function is the HTTP error code (200 if OK, e.g.)
  // - OutCustomHeader will handle Content-Type/Location
  // - if OutContentType is HTTP_RESP_STATICFILE (i.e. '!STATICFILE' aka
  // STATICFILE_CONTENT_TYPE in mORMot.pas), then OutContent is the UTF-8 file
  // name of a file which must be sent to the client via http.sys (much faster
  // than manual buffering/sending) and  the OutCustomHeader should
  // contain the proper 'Content-type: ....'
  TOnHttpServerRequest = function(Ctxt: TPnHttpServerContext): Cardinal of object;

  /// event handler used by THttpServerGeneric.OnBeforeBody property
  // - if defined, is called just before the body is retrieved from the client
  // - supplied parameters reflect the current input state
  // - should return STATUS_SUCCESS=200 to continue the process, or an HTTP
  // error code (e.g. STATUS_FORBIDDEN or STATUS_PAYLOADTOOLARGE) to reject
  // the request
  TOnHttpServerBeforeBody = function(const AURL,AMethod,AInHeaders,
    AInContentType,ARemoteIP: SockString; AContentLength: Integer;
    AUseSSL: Boolean): Cardinal of object;


  TPnHttpSysServer = class
  private const
    SHUTDOWN_FLAG = ULONG_PTR(-1);
  private
    fOnRequest: TOnHttpServerRequest;
    fOnBeforeBody: TOnHttpServerBeforeBody;
    fOnBeforeRequest: TOnHttpServerRequest;
    fOnAfterRequest: TOnHttpServerRequest;
    fOnAfterResponse: TOnHttpServerRequest;
    fMaximumAllowedContentLength: Cardinal;
    //服务名称
    fServerName: SockString;
    //接收上传数据块大小
    fReceiveBufferSize: Cardinal;
    /// list of all registered compression algorithms
    fCompress: THttpSocketCompressRecDynArray;
    /// set by RegisterCompress method
    fCompressAcceptEncoding: SockString;
    /// list of all registered URL
    fRegisteredUnicodeUrl: array of SynUnicode;


    FHttpApiVersion: HTTPAPI_VERSION;
    FServerSessionID: HTTP_SERVER_SESSION_ID;
    FUrlGroupID: HTTP_URL_GROUP_ID;
    FReqQueueHandle: THandle;
    FCompletionPort: THandle;


    FContextObjPool: TPNObjectPool;
    FIoThreadsCount: Integer;
    FContextObjCount: Integer;
    FIoThreads: TArray<TIoEventThread>;


    /// <summary>
    /// 创建ServerContext对象事件
    /// </summary>
    /// <returns></returns>
    function OnContextCreateObject: TPNObject;
    /// <summary>
    /// 取得线程数
    /// </summary>
    /// <returns>返回线程数(默认CPUCount*2+1)</returns>
    function GetIoThreads: Integer;
    /// <summary>
    /// 是否运行中
    /// </summary>
    /// <returns></returns>
    function GetIsRuning: Boolean;
    /// <summary>
    /// 解析注册URI
    /// </summary>
    /// <param name="ARoot">Uri路径</param>
    /// <param name="APort">端口</param>
    /// <param name="Https">是否https</param>
    /// <param name="ADomainName">域</param>
    /// <returns>返回供httpapi注册的URI(http://*:8080/)</returns>
    function RegURL(ARoot, APort: SockString; Https: Boolean; ADomainName: SockString): SynUnicode;
    /// <summary>
    /// 添加Uri注册
    /// </summary>
    /// <param name="ARoot">Uri路径</param>
    /// <param name="APort">端口</param>
    /// <param name="Https">是否https</param>
    /// <param name="ADomainName">域</param>
    /// <param name="OnlyDelete">是否只删除</param>
    /// <returns></returns>
    function AddUrlAuthorize(const ARoot, APort: SockString; Https: Boolean = False;
      const ADomainName: SockString='*'; OnlyDelete: Boolean = False): string;

    //Context Event
    function DoRequest(Ctxt: TPnHttpServerContext): Cardinal;
    function DoBeforeRequest(Ctxt: TPnHttpServerContext): Cardinal;
    function DoAfterRequest(Ctxt: TPnHttpServerContext): Cardinal;
    procedure DoAfterResponse(Ctxt: TPnHttpServerContext);

    /// IoEvent Handle functions
    procedure _HandleRequestHead(AContext: TPnHttpServerContext);
    procedure _HandleRequestBody(AContext: TPnHttpServerContext); inline;
    procedure _HandleResponseBody(AContext: TPnHttpServerContext); inline;
    procedure _HandleResponseEnd(AContext: TPnHttpServerContext); inline;
    /// ProcessIoEvent
    function ProcessIoEvent: Boolean; inline;

  public
    constructor Create(AIoThreadsCount: Integer = 0; AContextObjCount: Integer = 1000);
    destructor Destroy; override;
    /// <summary>
    /// 注册URI
    /// </summary>
    /// <param name="ARoot">Uri路径</param>
    /// <param name="APort">端口</param>
    /// <param name="Https">是否https</param>
    /// <param name="ADomainName">域</param>
    /// <param name="ARegisterURI">是否注册</param>
    /// <param name="AUrlContext">0</param>
    /// <returns>返回数组注册序号</returns>
    function AddUrl(const ARoot, APort: SockString; Https: Boolean = False;
      const ADomainName: SockString='*'; ARegisterURI: Boolean = False;
      AUrlContext: HTTP_URL_CONTEXT = 0): Integer;
    procedure Start;
    procedure Stop;

    procedure RegisterCompress(aFunction: THttpSocketCompress;
      aCompressMinSize: Integer = 1024);

    property OnRequest: TOnHttpServerRequest read fOnRequest write fOnRequest;
    property OnBeforeBody: TOnHttpServerBeforeBody read fOnBeforeBody write fOnBeforeBody;
    property OnBeforeRequest: TOnHttpServerRequest read fOnBeforeRequest write fOnBeforeRequest;
    property OnAfterRequest: TOnHttpServerRequest  read fOnAfterRequest write fOnAfterRequest;

    property MaximumAllowedContentLength: Cardinal read fMaximumAllowedContentLength
      write fMaximumAllowedContentLength;
    property ServerName: SockString read fServerName write fServerName;
    /// how many bytes are retrieved in a single call to ReceiveRequestEntityBody
    // - set by default to 1048576, i.e. 1 MB - practical limit is around 20 MB
    // - you may customize this value if you encounter HTTP error STATUS_NOTACCEPTABLE
    // (406) from client, corresponding to an ERROR_NO_SYSTEM_RESOURCES (1450)
    // exception on server side, when uploading huge data content
    property ReceiveBufferSize: Cardinal read fReceiveBufferSize write fReceiveBufferSize;

    property IsRuning: Boolean read GetIsRuning;

  end;


implementation

uses
  SynWinSock,
  uPNDebug;

var
  ServerContextNewCount: Integer = 0;
  ServerContextFreeCount: Integer = 0;

{ TPnHttpServerContext }
constructor TPnHttpServerContext.Create(AServer: TPnHttpSysServer);
begin
  AtomicIncrement(ServerContextNewCount);
  fServer := AServer;
  fReqPerHttpIoData := _NewIoData;
  fReqPerHttpIoData^.IoData := Self;
  SetLength(fReqBuf,BUFFERLEN); // space for Req^ + 16 KB of headers
  fReq := Pointer(fReqBuf);

  inherited Create;
end;

destructor TPnHttpServerContext.Destroy;
begin
  AtomicIncrement(ServerContextFreeCount);
  _FreeIoData(fReqPerHttpIoData);
  inherited;
end;

procedure TPnHttpServerContext.InitObject;
begin
  fReqPerHttpIoData^.BytesRead := 0;
  fReqPerHttpIoData^.Action := IoNone;
  fReqPerHttpIoData^.hFile := INVALID_HANDLE_VALUE;

  FillChar(Pointer(@fReqBuf[1])^, SizeOf(fReqBuf), 0);
  fReq := Pointer(fReqBuf);

  FillChar(fResp,sizeof(fResp),0);
  fRespSent := False;
  fOutStatusCode := 200;
end;



const
  /// the running Operating System
  XPOWEREDOS = {$ifdef MSWINDOWS} 'Windows' {$else}
                 {$ifdef LINUXNOTBSD} 'Linux' {$else} 'Posix' {$endif LINUXNOTBSD}
               {$endif MSWINDOWS};

  XPOWEREDPROGRAM = 'mORMot 1.18';
  XPOWEREDNAME = 'X-Powered-By';
  XPOWEREDVALUE = XPOWEREDPROGRAM + ' synopse.info';


procedure TPnHttpServerContext.SetHeaders(Resp: PHTTP_RESPONSE; P: PAnsiChar; var UnknownHeaders: HTTP_UNKNOWN_HEADERs);
////{$ifndef NOXPOWEREDNAME}
//const XPN: PAnsiChar = XPOWEREDNAME;
//      XPV: PAnsiChar = XPOWEREDVALUE;
////{$endif}
begin
  with Resp^ do
  begin
    Headers.pUnknownHeaders := PHTTP_UNKNOWN_HEADER(@UnknownHeaders[0]);
    {$ifdef NOXPOWEREDNAME}
    Headers.UnknownHeaderCount := 0;
    {$else}
    with UnknownHeaders[0] do begin
      pName := XPOWEREDNAME;
      NameLength := length(XPOWEREDNAME);
      pRawValue := XPOWEREDVALUE;
      RawValueLength := length(XPOWEREDVALUE);
    end;
    Headers.UnknownHeaderCount := 1;
    {$endif}
    if P<>nil then
    repeat
      while P^ in [#13,#10] do inc(P);
      if P^=#0 then
        break;
      P := AddCustomHeader(Resp, P,UnknownHeaders,false);
    until false;
  end;
end;


function TPnHttpServerContext.AddCustomHeader(Resp: PHTTP_RESPONSE; P: PAnsiChar;
  var UnknownHeaders: HTTP_UNKNOWN_HEADERs; ForceCustomHeader: Boolean): PAnsiChar;
const KNOWNHEADERS: array[HttpHeaderCacheControl..HttpHeaderWwwAuthenticate] of PAnsiChar = (
    'CACHE-CONTROL:','CONNECTION:','DATE:','KEEP-ALIVE:','PRAGMA:','TRAILER:',
    'TRANSFER-ENCODING:','UPGRADE:','VIA:','WARNING:','ALLOW:','CONTENT-LENGTH:',
    'CONTENT-TYPE:','CONTENT-ENCODING:','CONTENT-LANGUAGE:','CONTENT-LOCATION:',
    'CONTENT-MD5:','CONTENT-RANGE:','EXPIRES:','LAST-MODIFIED:',
    'ACCEPT-RANGES:','AGE:','ETAG:','LOCATION:','PROXY-AUTHENTICATE:',
    'RETRY-AFTER:','SERVER:','SET-COOKIE:','VARY:','WWW-AUTHENTICATE:');
var UnknownName: PAnsiChar;
    i: integer;
begin
  with Resp^ do
  begin
    if ForceCustomHeader then
      i := -1
    else
      i := IdemPCharArray(P,KNOWNHEADERS);
    // WebSockets need CONNECTION as unknown header
    if (i>=0) and (HTTP_HEADER_ID(i)<>HttpHeaderConnection) then
      with Headers.KnownHeaders[HTTP_HEADER_ID(i)] do begin
        while P^<>':' do inc(P);
        inc(P); // jump ':'
        while P^=' ' do inc(P);
        pRawValue := P;
        while P^>=' ' do inc(P);
        RawValueLength := P-pRawValue;
      end
    else begin
      UnknownName := P;
      while (P^>=' ') and (P^<>':') do inc(P);
      if P^=':' then
        with UnknownHeaders[Headers.UnknownHeaderCount] do begin
          pName := UnknownName;
          NameLength := P-pName;
          repeat inc(P) until P^<>' ';
          pRawValue := P;
          while P^>=' ' do inc(P);
          RawValueLength := P-pRawValue;
          if Headers.UnknownHeaderCount=high(UnknownHeaders) then begin
            SetLength(UnknownHeaders,Headers.UnknownHeaderCount+32);
            Headers.pUnknownHeaders := pointer(UnknownHeaders);
          end;
          inc(Headers.UnknownHeaderCount);
        end
      else
        while P^>=' ' do
          inc(P);
    end;
    result := P;
  end;
end;

procedure TPnHttpServerContext.SendError(StatusCode: Cardinal; const ErrorMsg: string; E: Exception);
var
  Msg: string;
  OutStatus,
  OutContent: SockString;
  dataChunk: HTTP_DATA_CHUNK;

  BytesSend: Cardinal;
  flags: Cardinal;
  hr: HRESULT;
begin
  //if fRespSent then Exit;
  fRespSent := True;
  try
    //default http StatusCode 200 OK
    fResp.StatusCode := StatusCode;
    OutStatus := StatusCodeToReason(StatusCode);
    fResp.pReason := PAnsiChar(OutStatus);
    fResp.ReasonLength := Length(OutStatus);
    //CurrentLog^.ProtocolStatus := StatusCode;
    Msg := format(
      '<html><body style="font-family:verdana;"><h1>Server Error %d: %s</h1><p>',
      [StatusCode,OutStatus]);
    if E<>nil then
      Msg := Msg+string(E.ClassName)+' Exception raised:<br>';
    OutContent := UTF8String(Msg)+HtmlEncode(
      {$ifdef UNICODE}UTF8String{$else}UTF8Encode{$endif}(ErrorMsg))
      {$ifndef NOXPOWEREDNAME}+'</p><p><small>'+XPOWEREDVALUE{$endif};
      //'text/html; charset=utf-8';

    dataChunk.DataChunkType := HttpDataChunkFromMemory;
    dataChunk.pBuffer := PAnsiChar(OutContent);
    dataChunk.BufferLength := Length(OutContent);

    with fResp do
    begin
      //dataChunks
      EntityChunkCount := 1;
      pEntityChunks := @dataChunk;
      //ContentType
      Headers.KnownHeaders[HttpHeaderContentType].RawValueLength := Length(HTML_CONTENT_TYPE);
      Headers.KnownHeaders[HttpHeaderContentType].pRawValue := PAnsiChar(HTML_CONTENT_TYPE);
    end;

    fReqPerHttpIoData^.BytesRead := 0;
    fReqPerHttpIoData^.Action := IoResponseEnd;

    flags := 0;
    BytesSend := 0;
    hr := HttpSendHttpResponse(
        fServer.fReqQueueHandle,
        fReq^.RequestId,
        flags,
        @fResp,
        nil,
        BytesSend,
        nil,
        0,
        POverlapped(fReqPerHttpIoData),
        nil);
    //Assert((hr=NO_ERROR) or (hr=ERROR_IO_PENDING));
    if (hr<>NO_ERROR) and (hr<>ERROR_IO_PENDING) then
      HttpCheck(hr);
  except
    on Exception do
      ; // ignore any HttpApi level errors here (client may crashed)
  end;
end;

function TPnHttpServerContext.SendResponse: Boolean;
var
  OutStatus,
  OutContentEncoding: SockString;
  CurrentLog: HTTP_LOG_FIELDS_DATA;
  Heads: HTTP_UNKNOWN_HEADERs;
  //dataChunk: array [0..1] of HTTP_DATA_CHUNK;
  dataChunk: HTTP_DATA_CHUNK;

  BytesSend: Cardinal;
  flags: Cardinal;
  hr: HRESULT;

begin
  if fRespSent then Exit(True);

  Result := True;
  fRespSent := True;
  SetLength(Heads, 64);

  //default http StatusCode 200 OK
  fResp.StatusCode := fOutStatusCode;
  OutStatus := StatusCodeToReason(fOutStatusCode);
	fResp.pReason := PAnsiChar(OutStatus);
	fResp.ReasonLength := Length(OutStatus);


//  // update log information 日志
//  if fServer.FHttpApiVersion.HttpApiMajorVersion>2 then
//    with fReq^,CurrentLog do begin
//      MethodNum := Verb;
//      UriStemLength := CookedUrl.AbsPathLength;
//      UriStem := CookedUrl.pAbsPath;
//      with Headers.KnownHeaders[HttpHeaderUserAgent] do begin
//        UserAgentLength := RawValueLength;
//        UserAgent := pRawValue;
//      end;
//      with Headers.KnownHeaders[HttpHeaderHost] do begin
//        HostLength := RawValueLength;
//        Host := pRawValue;
//      end;
//      with Headers.KnownHeaders[HttpHeaderReferer] do begin
//        ReferrerLength := RawValueLength;
//        Referrer := pRawValue;
//      end;
//      ProtocolStatus := HttpResponse.StatusCode;
//      ClientIp := pointer(Self.fRemoteIP);
//      ClientIpLength := length(Self.fRemoteIP);
//      Method := pointer(Self.fMethod);
//      MethodLength := length(Self.fMethod);
//      UserName := pointer(Self.fAuthenticatedUser);
//      UserNameLength := Length(Self.fAuthenticatedUser);
//    end;

  // send response
  fResp.Version := fReq^.Version;
  SetHeaders(@fResp,pointer(fOutCustomHeaders),Heads);

  if fServer.fCompressAcceptEncoding<>'' then
    AddCustomHeader(@fResp, pointer(fServer.fCompressAcceptEncoding),Heads,false);

  with fResp.Headers.KnownHeaders[HttpHeaderServer] do
  begin
    pRawValue := pointer(fServer.fServerName);
    RawValueLength := length(fServer.fServerName);
  end;

  if fOutContentType=HTTP_RESP_STATICFILE then begin
//      // response is file -> OutContent is UTF-8 file name to be served
//      FileHandle := FileOpen(
//        {$ifdef UNICODE}UTF8ToUnicodeString{$else}Utf8ToAnsi{$endif}(AContext.OutContent),
//        fmOpenRead or fmShareDenyNone);
//      if PtrInt(FileHandle)<0 then begin
//        SendError(STATUS_NOTFOUND,SysErrorMessage(GetLastError));
//        result := false; // notify fatal error
//      end;
//      try // http.sys will serve then close the file from kernel
//        DataChunkFile.DataChunkType := hctFromFileHandle;
//        DataChunkFile.FileHandle := FileHandle;
//        flags := 0;
//        DataChunkFile.ByteRange.StartingOffset.QuadPart := 0;
//        Int64(DataChunkFile.ByteRange.Length.QuadPart) := -1; // to eof
//        with Req^.Headers.KnownHeaders[reqRange] do begin
//          if (RawValueLength>6) and IdemPChar(pRawValue,'BYTES=') and
//             (pRawValue[6] in ['0'..'9']) then begin
//            SetString(Range,pRawValue+6,RawValueLength-6); // need #0 end
//            R := pointer(Range);
//            RangeStart := GetNextItemUInt64(R);
//            if R^='-' then begin
//              OutContentLength.LowPart := GetFileSize(FileHandle,@OutContentLength.HighPart);
//              DataChunkFile.ByteRange.Length.QuadPart := OutContentLength.QuadPart-RangeStart;
//              inc(R);
//              flags := HTTP_SEND_RESPONSE_FLAG_PROCESS_RANGES;
//              DataChunkFile.ByteRange.StartingOffset.QuadPart := RangeStart;
//              if R^ in ['0'..'9'] then begin
//                RangeLength := GetNextItemUInt64(R)-RangeStart+1;
//                if RangeLength<DataChunkFile.ByteRange.Length.QuadPart then
//                  // "bytes=0-499" -> start=0, len=500
//                  DataChunkFile.ByteRange.Length.QuadPart := RangeLength;
//              end; // "bytes=1000-" -> start=1000, to eof)
//              ContentRange := 'Content-Range: bytes ';
//              AppendI64(RangeStart,ContentRange);
//              AppendChar('-',ContentRange);
//              AppendI64(RangeStart+DataChunkFile.ByteRange.Length.QuadPart-1,ContentRange);
//              AppendChar('/',ContentRange);
//              AppendI64(OutContentLength.QuadPart,ContentRange);
//              AppendChar(#0,ContentRange);
//              Resp^.AddCustomHeader(@ContentRange[1],Heads,false);
//              Resp^.SetStatus(STATUS_PARTIALCONTENT,OutStatus);
//            end;
//          end;
//          with Resp^.Headers.KnownHeaders[respAcceptRanges] do begin
//             pRawValue := 'bytes';
//             RawValueLength := 5;
//          end;
//        end;
//        Resp^.EntityChunkCount := 1;
//        Resp^.pEntityChunks := @DataChunkFile;
//        Http.SendHttpResponse(fReqQueue,
//          Req^.RequestId,flags,Resp^,nil,bytesSent,nil,0,nil,fLogData);
//      finally
//        FileClose(FileHandle);
//      end;
  end else begin
    // response is in OutContent -> send it from memory
    if fOutContentType=HTTP_RESP_NORESPONSE then
      fOutContentType := ''; // true HTTP always expects a response
    //gzip压缩
    if fServer.fCompress<>nil then begin
      with fResp.Headers.KnownHeaders[HttpHeaderContentEncoding] do
        if RawValueLength=0 then begin
          // no previous encoding -> try if any compression
          OutContentEncoding := CompressDataAndGetHeaders(fInCompressAccept,
            fServer.fCompress,fOutContentType,fOutContent);
          pRawValue := pointer(OutContentEncoding);
          RawValueLength := length(OutContentEncoding);
        end;
    end;

    if fOutContent<>'' then
    begin
      dataChunk.DataChunkType := HttpDataChunkFromMemory;
      dataChunk.pBuffer := PAnsiChar(fOutContent);
      dataChunk.BufferLength := Length(fOutContent);

      with fResp do
      begin
        //dataChunks
        EntityChunkCount := 1;
        pEntityChunks := @dataChunk;
        //ContentType
        Headers.KnownHeaders[HttpHeaderContentType].RawValueLength := Length(fOutContentType);
        Headers.KnownHeaders[HttpHeaderContentType].pRawValue := PAnsiChar(fOutContentType);
      end;
    end;

    fReqPerHttpIoData^.BytesRead := 0;
    fReqPerHttpIoData^.Action := IoResponseEnd;

    flags := 0;
    BytesSend := 0;
    hr := HttpSendHttpResponse(
        fServer.fReqQueueHandle,
        fReq^.RequestId,
        flags,
        @fResp,
        nil,
        BytesSend,
        nil,
        0,
        POverlapped(fReqPerHttpIoData),
        nil);
    //Assert((hr=NO_ERROR) or (hr=ERROR_IO_PENDING));
    //if not ((hr=NO_ERROR) or (hr=ERROR_IO_PENDING)) then
    //  HttpCheck(hr);
    if (hr<>NO_ERROR) and (hr<>ERROR_IO_PENDING) then
      SendError(STATUS_NOTACCEPTABLE,SysErrorMessagePerModule(hr,HttpApiDllName));


//          flags := 0;
//          BytesSend := 0;
//          hr := HttpSendResponseEntityBody(
//              fServer.fReqQueueHandle,
//              fReq^.RequestId,
//              flags,
//              1,
//              @dataChunk[0],
//              BytesSend,
//              nil,
//              0,
//              POverlapped(fReqPerHttpIoData),
//              nil);

  end;

end;



function TPnHttpServerContext._NewIoData: PPerHttpIoData;
begin
  System.New(Result);
  FillChar(Result^, SizeOf(TPerHttpIoData), 0);
end;

procedure TPnHttpServerContext._FreeIoData(P: PPerHttpIoData);
begin
  P.IoData := nil;
  System.Dispose(P);
end;


{ TIoEventThread }
constructor TIoEventThread.Create(AServer: TPnHttpSysServer);
begin
  inherited Create(True);
  FServer := AServer;
  Suspended := False;
end;

procedure TIoEventThread.Execute;
{$IFDEF DEBUG}
var
  LRunCount: Int64;
{$ENDIF}
begin
  {$IFDEF DEBUG}
  LRunCount := 0;
  {$ENDIF}
  while not Terminated do
  begin
    try
      if not FServer.ProcessIoEvent then
        Break;
    except
      {$IFDEF DEBUG}
      on e: Exception do
        debugEx('%s Io线程ID %d, 异常 %s, %s', [FServer.ClassName, Self.ThreadID, e.ClassName, e.Message]);
      {$ENDIF}
    end;
    {$IFDEF DEBUG}
    Inc(LRunCount)
    {$ENDIF};
  end;
  {$IFDEF DEBUG}
  debugEx('%s Io线程ID %d, 被调用了 %d 次', [FServer.ClassName, Self.ThreadID, LRunCount]);
  {$ENDIF}
end;



{ TPnHttpSysServer }
constructor TPnHttpSysServer.Create(AIoThreadsCount: Integer; AContextObjCount: Integer);
var
  hr: HRESULT;
  LUrlContext: HTTP_URL_CONTEXT;
  LUri: SynUnicode;
  LQueueName: SynUnicode;
  Binding: HTTP_BINDING_INFO;
  hNewCompletionPort: THandle;
begin
  inherited Create;
  fServerName := 'mORMot ('+XPOWEREDOS+')';
  fMaximumAllowedContentLength := 0;
  //接收post的数据块大小
  fReceiveBufferSize := 1048576; // i.e. 1 MB


  LoadHttpApiLibrary;
  //Http Version Initialize
  FHttpApiVersion := HTTPAPI_VERSION_2;
  hr := HttpInitialize(FHttpApiVersion,HTTP_INITIALIZE_CONFIG or HTTP_INITIALIZE_SERVER,nil);
  //Assert(hr=NO_ERROR, 'HttpInitialize Error');
  EHttpApiServer.RaiseOnError('HttpInitialize',hr);

  if FHttpApiVersion.HttpApiMajorVersion>1 then
  begin
    //Create FServerSessionID
    hr := HttpCreateServerSession(FHttpApiVersion,FServerSessionID,0);
    //Assert(hr=NO_ERROR, 'HttpCreateServerSession Error');
    EHttpApiServer.RaiseOnError('HttpCreateServerSession',hr);


//	//enable logging
//	CStringW strLogDir = GetLoggingDirectory();
//	HTTP_LOGGING_INFO LogginInfo;
//	ZeroMemory(&LogginInfo,sizeof(HTTP_LOGGING_INFO));
//	LogginInfo.Flags.Present=1;
//	LogginInfo.Format=HttpLoggingTypeW3C;
//	LogginInfo.Fields=HTTP_LOG_FIELD_TIME|HTTP_LOG_FIELD_CLIENT_IP;
//	LogginInfo.DirectoryName=(LPCWSTR)strLogDir;
//	LogginInfo.DirectoryNameLength=strLogDir.GetLength()*2;
//	LogginInfo.RolloverType=HttpLoggingRolloverDaily;
//	ul=HttpSetServerSessionProperty(ServerSessionID,HttpServerLoggingProperty,&LogginInfo,sizeof(HTTP_LOGGING_INFO));
//	assert(ul==NO_ERROR);


    //Create FUrlGroupID
    hr := HttpCreateUrlGroup(FServerSessionID,FUrlGroupID,0);
    //Assert(hr=NO_ERROR, 'HttpCreateUrlGroup Error');
    EHttpApiServer.RaiseOnError('HttpCreateUrlGroup',hr);

//    //test port 8080
//    LUrlContext := 0;
//    LUri := RegURL('/', '8080', False, '+');
//    hr := HttpAddUrlToUrlGroup(FUrlGroupID,Pointer(LUri),LUrlContext,0);
//    Assert(hr=NO_ERROR, 'HttpAddUrlToUrlGroup Error');

    //Create FReqQueueHandle
    LQueueName := '';
//    if QueueName='' then
//      BinToHexDisplayW(@fServerSessionID,SizeOf(fServerSessionID),QueueName);
    hr := HttpCreateRequestQueue(FHttpApiVersion,Pointer(LQueueName),nil,0,FReqQueueHandle);
    //Assert(hr=NO_ERROR, 'HttpCreateRequestQueue Error');
    EHttpApiServer.RaiseOnError('HttpCreateRequestQueue',hr);

    //SetUrlGroupProperty
    Binding.Flags := 1;
    Binding.RequestQueueHandle := FReqQueueHandle;
    hr := HttpSetUrlGroupProperty(FUrlGroupID,HttpServerBindingProperty,@Binding,SizeOf(HTTP_BINDING_INFO));
    //Assert(hr=NO_ERROR, 'HttpSetUrlGroupProperty Error');
    EHttpApiServer.RaiseOnError('HttpSetUrlGroupProperty',hr);
  end
  else begin
    //httpapi 1.0
    //CreateHttpHandle
    hr := HttpCreateHttpHandle(FReqQueueHandle, 0);
    //Assert(hr=NO_ERROR, 'HttpCreateHttpHandle Error');
    EHttpApiServer.RaiseOnError('HttpCreateHttpHandle',hr);
  end;

  //Create IO Complet
  FCompletionPort := CreateIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 0);
  hNewCompletionPort := CreateIoCompletionPort(FReqQueueHandle, FCompletionPort, ULONG_PTR(FReqQueueHandle), 0);
  Assert(FCompletionPort=hNewCompletionPort, 'CreateIoCompletionPort Error.');

  FIoThreadsCount := AIoThreadsCount;
  FContextObjCount := AContextObjCount;
  FContextObjPool := TPNObjectPool.Create;
end;

destructor TPnHttpSysServer.Destroy;
var
  I: Integer;
begin
  Stop;

  //Close IO Complet
  if FCompletionPort<>0 then begin
    CloseHandle(FCompletionPort);
    FCompletionPort := 0;
  end;

  if FReqQueueHandle<>0 then begin
    if FHttpApiVersion.HttpApiMajorVersion>1 then begin
      if FUrlGroupID<>0 then begin
        HttpRemoveUrlFromUrlGroup(FUrlGroupID,nil,HTTP_URL_FLAG_REMOVE_ALL);
        HttpCloseUrlGroup(FUrlGroupID);
        FUrlGroupID := 0;
      end;
      HttpCloseRequestQueue(FReqQueueHandle);
      if FServerSessionID<>0 then begin
        HttpCloseServerSession(FServerSessionID);
        FServerSessionID := 0;
      end;
    end else begin
      for I := 0 to high(fRegisteredUnicodeUrl) do
      HttpRemoveUrl(FReqQueueHandle,Pointer(fRegisteredUnicodeUrl[i]));
      CloseHandle(FReqQueueHandle);
    end;
    FReqQueueHandle := 0;
    HttpTerminate(HTTP_INITIALIZE_CONFIG or HTTP_INITIALIZE_SERVER,nil);
  end;

//  debugEx('PNPool1 act: %d, res: %d', [FContextObjPool.FObjectMgr.GetActiveObjectCount, FContextObjPool.FObjectRes.GetObjectCount]);
//  debugEx('PNPool2 new: %d, free: %d', [FContextObjPool.FObjectRes.FNewObjectCount, FContextObjPool.FObjectRes.FFreeObjectCount]);
  if Assigned(FContextObjPool) then
  begin
    FContextObjPool.FreeAllObjects;
    FContextObjPool.Free;
  end;
//  debugEx('System3 new: %d, free: %d', [ServerContextNewCount, ServerContextFreeCount]);

  inherited Destroy;
end;




{ private functions start ===== }
function TPnHttpSysServer.OnContextCreateObject: TPNObject;
begin
  Result := TPnHttpServerContext.Create(Self);
end;

function TPnHttpSysServer.GetIoThreads: Integer;
begin
  if (FIoThreadsCount > 0) then
    Result := FIoThreadsCount
  else
    Result := CPUCount * 2 + 1;
end;

function TPnHttpSysServer.GetIsRuning: Boolean;
begin
  Result := (FIoThreads <> nil);
end;

function TPnHttpSysServer.RegURL(ARoot, APort: SockString; Https: Boolean; ADomainName: SockString): SynUnicode;
const
  Prefix: array[Boolean] of SockString = ('http://','https://');
  DEFAULT_PORT: array[Boolean] of SockString = ('80','443');
begin
  if APort='' then
    APort := DEFAULT_PORT[Https];
  ARoot := Trim(ARoot);
  ADomainName := Trim(ADomainName);
  if ADomainName='' then
  begin
    Result := '';
    Exit;
  end;
  if ARoot<>'' then
  begin
    if ARoot[1]<>'/' then
      insert('/',ARoot,1);
    if ARoot[length(ARoot)]<>'/' then
      ARoot := ARoot+'/';
  end else
    ARoot := '/'; // allow for instance 'http://*:2869/'
  ARoot := Prefix[Https]+ADomainName+':'+APort+ARoot;
  Result := SynUnicode(ARoot);
end;

function TPnHttpSysServer.AddUrlAuthorize(const ARoot: SockString; const APort: SockString;
  Https: Boolean; const ADomainName: SockString; OnlyDelete: Boolean): string;
const
  /// will allow AddUrl() registration to everyone
  // - 'GA' (GENERIC_ALL) to grant all access
  // - 'S-1-1-0'	defines a group that includes all users
  HTTPADDURLSECDESC: PWideChar = 'D:(A;;GA;;;S-1-1-0)';
var
  prefix: SynUnicode;
  Error: HRESULT;
  Config: HTTP_SERVICE_CONFIG_URLACL_SET;
begin
  try
    LoadHttpApiLibrary;
    prefix := RegURL(aRoot, aPort, Https, aDomainName);
    if prefix='' then
      result := 'Invalid parameters'
    else begin
      FHttpApiVersion := HTTPAPI_VERSION_2;
      Error := HttpInitialize(FHttpApiVersion,HTTP_INITIALIZE_CONFIG or HTTP_INITIALIZE_SERVER,nil);
      //Assert(hr=NO_ERROR, 'HttpInitialize Error');
      EHttpApiServer.RaiseOnError('HttpInitialize',Error);
      try
        fillchar(Config,sizeof(Config),0);
        Config.KeyDesc.pUrlPrefix := pointer(prefix);
        // first delete any existing information
        Error := HttpDeleteServiceConfiguration(0,HttpServiceConfigUrlAclInfo,@Config,Sizeof(Config),nil);
        // then add authorization rule
        if not OnlyDelete then begin
          Config.KeyDesc.pUrlPrefix := pointer(prefix);
          Config.ParamDesc.pStringSecurityDescriptor := HTTPADDURLSECDESC;
          Error := HttpSetServiceConfiguration(0,HttpServiceConfigUrlAclInfo,@Config,Sizeof(Config),nil);
        end;
        if (Error<>NO_ERROR) and (Error<>ERROR_ALREADY_EXISTS) then
          raise EHttpApiServer.Create('HttpSetServiceConfiguration',Error);
        result := ''; // success
      finally
        HttpTerminate(HTTP_INITIALIZE_CONFIG);
      end;
    end;
  except
    on E: Exception do
      result := E.Message;
  end;
end;

function TPnHttpSysServer.DoRequest(Ctxt: TPnHttpServerContext): Cardinal;
begin
//  if fShutdownInProgress then
//    result := STATUS_NOTFOUND
//  else begin
//    NotifyThreadStart(Ctxt.ConnectionThread);
//    if Assigned(OnRequest) then
//      result := OnRequest(Ctxt) else
//      result := STATUS_NOTFOUND;
//  end;
  if Assigned(fOnRequest) then
    result := fOnRequest(Ctxt)
  else
    result := STATUS_NOTFOUND;
end;

function TPnHttpSysServer.DoBeforeRequest(Ctxt: TPnHttpServerContext): cardinal;
begin
  if Assigned(fOnBeforeRequest) then
    result := fOnBeforeRequest(Ctxt) else
    result := 0;
end;

function TPnHttpSysServer.DoAfterRequest(Ctxt: TPnHttpServerContext): cardinal;
begin
  if Assigned(fOnAfterRequest) then
    result := fOnAfterRequest(Ctxt) else
    result := 0;
end;

procedure TPnHttpSysServer.DoAfterResponse(Ctxt: TPnHttpServerContext);
begin
  if Assigned(fOnAfterResponse) then
    fOnAfterResponse(Ctxt);
end;

procedure TPnHttpSysServer._HandleRequestHead(AContext: TPnHttpServerContext);
type
  TVerbText = array[HttpVerbOPTIONS..pred(HttpVerbMaximum)] of SockString;
const
  VERB_TEXT: TVerbText = (
    'OPTIONS','GET','HEAD','POST','PUT','DELETE','TRACE','CONNECT','TRACK',
    'MOVE','COPY','PROPFIND','PROPPATCH','MKCOL','LOCK','UNLOCK','SEARCH');
var
  BytesRead: Cardinal;
  hr: HRESULT;
  Verbs: TVerbText; // to avoid memory allocation
  LContext: TPnHttpServerContext;
  I: Integer;
  //pReqInfo: PHTTP_REQUEST_INFO;
  flags: Cardinal;
begin

  if (AContext<>nil) then
  begin
    Verbs := VERB_TEXT;
    // parse method and headers
    with AContext do
    begin
      fReqBufLen := fReqPerHttpIoData^.BytesRead;
      fConnectionID := fReq^.ConnectionId;
      //LContext.fHttpApiRequest := Req;
      fURL := fReq^.pRawUrl;
      if fReq^.Verb in [low(Verbs)..high(Verbs)] then
        fMethod := Verbs[fReq^.Verb]
      else
        SetString(fMethod,fReq^.pUnknownVerb,fReq^.UnknownVerbLength);
      with fReq^.Headers.KnownHeaders[HttpHeaderContentType] do
        SetString(fInContentType,pRawValue,RawValueLength);
      with fReq^.Headers.KnownHeaders[HttpHeaderAcceptEncoding] do
        SetString(fInAcceptEncoding,pRawValue,RawValueLength);
      fInCompressAccept := ComputeContentEncoding(fCompress,Pointer(fInAcceptEncoding));
      fUseSSL := fReq^.pSslInfo<>nil;
      fInHeaders := RetrieveHeaders(fReq^,fRemoteIPHeaderUpper,fRemoteIP);

      // retrieve any SetAuthenticationSchemes() information
      if Byte(fAuthenticationSchemes)<>0 then // set only with HTTP API 2.0
      begin
        for i := 0 to fReq^.RequestInfoCount-1 do
          if fReq^.pRequestInfo^[i].InfoType=HttpRequestInfoTypeAuth then
            with PHTTP_REQUEST_AUTH_INFO(fReq^.pRequestInfo^[i].pInfo)^ do begin
              case AuthStatus of
                HttpAuthStatusSuccess:
                if AuthType>HttpRequestAuthTypeNone then begin
                  byte(AContext.fAuthenticationStatus) := ord(AuthType)+1;
                  if AccessToken<>0 then
                    GetDomainUserNameFromToken(AccessToken,AContext.fAuthenticatedUser);
                end;
                HttpAuthStatusFailure:
                  AContext.fAuthenticationStatus := hraFailed;
              end;
            end;

//        pReqInfo := fReq^.pRequestInfo;
//        while pReqInfo<>nil do
//        begin
//          if pReqInfo^.InfoType=HttpRequestInfoTypeAuth then
//            with PHTTP_REQUEST_AUTH_INFO(pReqInfo.pInfo)^ do begin
//              case AuthStatus of
//                HttpAuthStatusSuccess:
//                  if AuthType>HttpRequestAuthTypeNone then begin
//                    Byte(fAuthenticationStatus) := ord(AuthType)+1;
//                    if AccessToken<>0 then
//                      GetDomainUserNameFromToken(AccessToken,fAuthenticatedUser);
//                  end;
//                HttpAuthStatusFailure:
//                  fAuthenticationStatus := hraFailed;
//              end;
//            end;
//
//          //next ReqInfo
//          Inc(pReqInfo);
//        end;

      end;


      // retrieve request body
      if HTTP_REQUEST_FLAG_MORE_ENTITY_BODY_EXISTS and fReq^.Flags<>0 then
      begin
        with fReq^.Headers.KnownHeaders[HttpHeaderContentLength] do
          fInContentLength := GetCardinal(pRawValue,pRawValue+RawValueLength);
        with fReq^.Headers.KnownHeaders[HttpHeaderContentEncoding] do
          SetString(fInContentEncoding,pRawValue,RawValueLength);

        //fInContentLength长度限制
        if (fInContentLength>0) and (MaximumAllowedContentLength>0) and
           (fInContentLength>MaximumAllowedContentLength) then begin
          SendError(STATUS_PAYLOADTOOLARGE,'Rejected');
          //continue;
          Exit;
        end;

        if Assigned(OnBeforeBody) then begin
          with AContext do
            hr := OnBeforeBody(fURL,fMethod,fInHeaders,fInContentType,fRemoteIP,fInContentLength,fUseSSL);
          if hr<>STATUS_SUCCESS then begin
            SendError(hr,'Rejected');
            //continue;
            Exit;
          end;
        end;

        //发起收取RequestBody等待
        if fInContentLength<>0 then
        begin
          SetLength(fInContent,fInContentLength);
          fInContentLengthRead := 0;
          //数据指针
          fInContentBufRead := Pointer(fInContent);
          fReqPerHttpIoData^.BytesRead := 0;
          fReqPerHttpIoData^.Action := IoRequestBody;
          //fReqPerHttpIoData^.HttpRequestId := fReqPerHttpIoData^.HttpRequestId;
          fReqPerHttpIoData^.hFile := INVALID_HANDLE_VALUE;
          _HandleRequestBody(AContext);

        end;

      end
      else begin
        //无post数据
        _HandleResponseBody(AContext);

      end;

    end;

  end;


  try
    //发起一条新的RequestHead等待
    //LContext := TPnHttpServerContext.Create(Self);
    LContext := TPnHttpServerContext(FContextObjPool.AllocateObject);
    LContext.InitObject;

    LContext.fReqPerHttpIoData^.BytesRead := 0;
    LContext.fReqPerHttpIoData^.Action := IoRequestHead;
    //LContext.fReqPerHttpIoData^.HttpRequestId := HTTP_NULL_ID;    LContext.fReqPerHttpIoData^.hFile := INVALID_HANDLE_VALUE;

    BytesRead := 0;
    hr := HttpReceiveHttpRequest(
      FReqQueueHandle,
      HTTP_NULL_ID, //LContext.fReqPerHttpIoData^.HttpRequestId,
      0, //Only the request headers are retrieved; the entity body is not copied.
      LContext.fReq,
      BUFFERLEN,
      BytesRead,
      POverlapped(LContext.fReqPerHttpIoData));
    //Assert((hr=NO_ERROR) or (hr=ERROR_IO_PENDING));
    //if not ((hr=NO_ERROR) or (hr=ERROR_IO_PENDING)) then
    //  HttpCheck(hr);
    if (hr<>NO_ERROR) and (hr<>ERROR_IO_PENDING) then
      LContext.SendError(STATUS_NOTACCEPTABLE,SysErrorMessagePerModule(hr,HttpApiDllName));
  except
    raise
  end;


end;

procedure TPnHttpSysServer._HandleRequestBody(AContext: TPnHttpServerContext);
var
  BytesRead: Cardinal;
  flags: Cardinal;
  hr: HRESULT;
  I: Integer;
begin
  try
    with AContext do
    begin
      if fReqPerHttpIoData^.BytesRead>0 then
      begin
        //计算已接收数据
        inc(fInContentLengthRead,fReqPerHttpIoData^.BytesRead);
        DebugEx('_HandleRequestBody:%d,%d', [fInContentLengthRead,fInContentLength]);
//        //数据指针偏移
//        inc(fInContentBufRead,fReqPerHttpIoData^.BytesRead);
        if fInContentLengthRead>=fInContentLength then
        begin
          //数据已接收完成
          //gzip解码
          if fInContentEncoding<>'' then
            for i := 0 to high(fCompress) do
              if fCompress[i].Name=fInContentEncoding then begin
                fCompress[i].Func(fInContent,false); // uncompress
                break;
              end;

          _HandleResponseBody(AContext);
          Exit;
        end;
      end;

      fInContentLengthChunk := fInContentLength-fInContentLengthRead;
      if (fReceiveBufferSize>=1024) and (fInContentLengthChunk>fReceiveBufferSize) then
        fInContentLengthChunk := fReceiveBufferSize;
      //数据指针
      //fInContentBufRead := Pointer(Cardinal(Pointer(fInContent))+fInContentLengthRead);
      //fInContentBufRead := Pointer(PByte(fInContent)+fInContentLengthRead);
      fInContentBufRead := Pointer(PAnsiChar(fInContent)+fInContentLengthRead);
      BytesRead := 0;
      if FHttpApiVersion.HttpApiMajorVersion>1 then // speed optimization for Vista+
        flags := HTTP_RECEIVE_REQUEST_ENTITY_BODY_FLAG_FILL_BUFFER
      else
        flags := 0;
      hr := HttpReceiveRequestEntityBody(
        FReqQueueHandle,
        fReq^.RequestId,
        flags,
        fInContentBufRead,
        fInContentLengthChunk,
        BytesRead,
        POverlapped(fReqPerHttpIoData));
      DebugEx('HttpReceiveRequestEntityBody:%d', [hr]);
      if (hr=ERROR_HANDLE_EOF) then
      begin
        //end of request body
        hr := NO_ERROR;
        Exit;
      end
      else begin
        //Assert((hr=NO_ERROR) or (hr=ERROR_IO_PENDING));
        //if not ((hr=NO_ERROR) or (hr=ERROR_IO_PENDING)) then
        //  HttpCheck(hr);
        if (hr<>NO_ERROR) and (hr<>ERROR_IO_PENDING) then
          SendError(STATUS_NOTACCEPTABLE,SysErrorMessagePerModule(hr,HttpApiDllName));
        Exit;
      end;

    end;

  except
    raise;
  end;
end;

//处理数据发送
procedure TPnHttpSysServer._HandleResponseBody(AContext: TPnHttpServerContext);
var
  AfterStatusCode: Cardinal;
begin
  // compute response
  try
    AContext.fOutContent := '';
    AContext.fOutContentType := '';
    AContext.fRespSent := false;
    AContext.fOutStatusCode := DoBeforeRequest(AContext);
    if AContext.fOutStatusCode>0 then
      if not AContext.SendResponse or (AContext.fOutStatusCode<>STATUS_ACCEPTED) then
        //continue;
        Exit;
    AContext.fOutStatusCode := DoRequest(AContext);
    AfterStatusCode := DoAfterRequest(AContext);
    if AfterStatusCode>0 then
      AContext.fOutStatusCode := AfterStatusCode;
    // send response
    if not AContext.fRespSent then
      if not AContext.SendResponse then
        Exit;
    DoAfterResponse(AContext);
  except
    on E: Exception do
      // handle any exception raised during process: show must go on!
      if not AContext.fRespSent then
      if not E.InheritsFrom(TPnHttpSysServer) or // ensure still connected
         (EHttpApiServer(E).LastError<>HTTPAPI_ERROR_NONEXISTENTCONNECTION) then
        AContext.SendError(STATUS_SERVERERROR,E.Message,E);
  end;
end;

procedure TPnHttpSysServer._HandleResponseEnd(AContext: TPnHttpServerContext);
begin
  //AContext.Free;
  FContextObjPool.ReleaseObject(AContext)
end;

function TPnHttpSysServer.ProcessIoEvent: Boolean;
var
  LBytesRead: Cardinal;
  LReqQueueHandle: THandle;
  LPerHttpIoData: PPerHttpIoData;
begin
  if not GetQueuedCompletionStatus(FCompletionPort, LBytesRead, ULONG_PTR(LReqQueueHandle), POverlapped(LPerHttpIoData), INFINITE) then
  begin
    // 出错了, 并且完成数据也都是空的,
    // 这种情况即便重试, 应该也会继续出错, 最好立即终止IO线程
    if (LPerHttpIoData = nil) then
    begin
//      {$IFDEF DEBUG}
//      _LogLastOsError;
//      {$ENDIF}
      Exit(False);
    end;

    //出错了, 但是完成数据不是空的, 需要重试
    _HandleResponseEnd(LPerHttpIoData^.IoData);
    Exit(True);
  end;

  // 主动调用了 StopLoop
  if (LBytesRead = 0) and (ULONG_PTR(LPerHttpIoData) = SHUTDOWN_FLAG) then
    Exit(False);

  // 由于未知原因未获取到完成数据, 但是返回的错误代码又是正常
  // 这种情况需要进行重试(返回True之后IO线程会再次调用ProcessIoEvent)
  if (LPerHttpIoData = nil) then
    Exit(True);

  //缓冲区长度
  LPerHttpIoData^.BytesRead := LBytesRead;

  case LPerHttpIoData.Action of
    IoRequestHead: _HandleRequestHead(LPerHttpIoData^.IoData);
    IoRequestBody: _HandleRequestBody(LPerHttpIoData^.IoData);
    //IoResponseBody: ;
    IoResponseEnd: _HandleResponseEnd(LPerHttpIoData^.IoData);
  end;

  Result := True;
end;
{ private functions end ===== }



{ public functions start ===== }
function TPnHttpSysServer.AddUrl(const ARoot, aPort: SockString; Https: Boolean;
  const ADomainName: SockString; ARegisterURI: Boolean; AUrlContext: HTTP_URL_CONTEXT): Integer;
var
  LUri: SynUnicode;
  n: Integer;
begin
  Result := -1;
  if (FReqQueueHandle=0) then
    Exit;
  LUri := RegURL(ARoot, APort, Https, ADomainName);
  if LUri='' then
    Exit; // invalid parameters
  if ARegisterURI then
    AddUrlAuthorize(ARoot, APort, Https, ADomainName);
  if FHttpApiVersion.HttpApiMajorVersion>1 then
    Result := HttpAddUrlToUrlGroup(fUrlGroupID,Pointer(LUri),AUrlContext)
  else
    Result := HttpAddUrl(FReqQueueHandle,Pointer(LUri));
  if Result=NO_ERROR then
  begin
    n := length(fRegisteredUnicodeUrl);
    SetLength(fRegisteredUnicodeUrl,n+1);
    fRegisteredUnicodeUrl[n] := LUri;
  end;
end;

procedure TPnHttpSysServer.Start;
var
  I: Integer;
begin
  if (FIoThreads <> nil) then
    Exit;

  FContextObjPool.FOnCreateObject := OnContextCreateObject;
  FContextObjPool.InitObjectPool(FContextObjCount);

  SetLength(FIoThreads, GetIoThreads);
  for I := 0 to Length(FIoThreads)-1 do
    FIoThreads[I] := TIoEventThread.Create(Self);

  // 给每个IO线程投递一个Request
  for I := 0 to Length(FIoThreads)-1 do
    _HandleRequestHead(nil);
end;

procedure TPnHttpSysServer.Stop;
var
  I: Integer;
begin
  if (FIoThreads = nil) then
    Exit;

  for I := 0 to Length(FIoThreads) - 1 do
    PostQueuedCompletionStatus(FCompletionPort, 0, 0, POverlapped(SHUTDOWN_FLAG));

  for I := 0 to Length(FIoThreads) - 1 do
  begin
    FIoThreads[I].WaitFor;
    FreeAndNil(FIoThreads[I]);
  end;
  FIoThreads := nil;

  debugEx('PNPool1 act: %d, res: %d', [FContextObjPool.FObjectMgr.GetActiveObjectCount, FContextObjPool.FObjectRes.GetObjectCount]);
  debugEx('PNPool2 new: %d, free: %d', [FContextObjPool.FObjectRes.FNewObjectCount, FContextObjPool.FObjectRes.FFreeObjectCount]);
  FContextObjPool.FreeAllObjects;
  debugEx('System3 new: %d, free: %d', [ServerContextNewCount, ServerContextFreeCount]);
end;

procedure TPnHttpSysServer.RegisterCompress(aFunction: THttpSocketCompress;
  aCompressMinSize: Integer);
begin
  RegisterCompressFunc(fCompress,aFunction,fCompressAcceptEncoding,aCompressMinSize);
end;

{ public functions end ===== }


var
  WsaDataOnce: TWSADATA;

initialization

  if InitSocketInterface then
    WSAStartup(WinsockLevel, WsaDataOnce)
  else
    fillchar(WsaDataOnce,sizeof(WsaDataOnce),0);

finalization

  if WsaDataOnce.wVersion<>0 then
    try
      {$ifdef MSWINDOWS}
      if Assigned(WSACleanup) then
        WSACleanup;
      {$endif}
    finally
      fillchar(WsaDataOnce,sizeof(WsaDataOnce),0);
    end;

end.
