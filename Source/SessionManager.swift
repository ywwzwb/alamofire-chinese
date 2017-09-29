//
//  SessionManager.swift
//
//  Copyright (c) 2014-2017 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// 负责创建和管理请求(Request)对象, 以及内部的 NSURLSession
/// Responsible for creating and managing `Request` objects, as well as their underlying `NSURLSession`.
open class SessionManager {

    //
    // MARK: - Helper Types 辅助类型
    
    /// 定义是否 MultipartFormData 编码是否成功, 以及含有一个编码过的数据
    /// Defines whether the `MultipartFormData` encoding was successful and contains result of the encoding as
    /// associated values.
    /// - 成功, 表示一个成功的 MultipartFormData 编码, 并同时返回一个 UploadRequest 以及对应的 streaming 信息
    /// - Success: Represents a successful `MultipartFormData` encoding and contains the new `UploadRequest` along with
    ///            streaming information.
    /// - 失败 用于表示MultipartFormData 编码失败, 并返回一个错误原因
    /// - Failure: Used to represent a failure in the `MultipartFormData` encoding and also contains the encoding
    ///            error.
    public enum MultipartFormDataEncodingResult {
        case success(request: UploadRequest, streamingFromDisk: Bool, streamFileURL: URL?)
        case failure(Error)
    }
    
    // MARK: - Properties 属性
    
    /// 一个SessionManager默认实例, 被Alamofire 顶层的请求方法所使用, 同时也可以直接满足任何的临时请求
    /// A default instance of `SessionManager`, used by top-level Alamofire request methods, and suitable for use
    /// directly for any ad hoc requests.
    /// 内部使用默认的 http 头, 默认的URLSessionConfiguration
    open static let `default`: SessionManager = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = SessionManager.defaultHTTPHeaders

        return SessionManager(configuration: configuration)
    }()
    
    /// 默认请求头, 包含了Accept-Encoding", "Accept-Language" 及 "User-Agent"
    /// Creates default values for the "Accept-Encoding", "Accept-Language" and "User-Agent" headers.
    open static let defaultHTTPHeaders: HTTPHeaders = {
        // 设置编码类型(gzip)
        // Accept-Encoding HTTP Header; see https://tools.ietf.org/html/rfc7230#section-4.2.3
        let acceptEncoding: String = "gzip;q=1.0, compress;q=0.5"
        // 设置语言
        // Accept-Language HTTP Header; see https://tools.ietf.org/html/rfc7231#section-5.3.5
        let acceptLanguage = Locale.preferredLanguages.prefix(6).enumerated().map { index, languageCode in
            let quality = 1.0 - (Double(index) * 0.1)
            return "\(languageCode);q=\(quality)"
        }.joined(separator: ", ")
        // 设置 ua
        // User-Agent Header; see https://tools.ietf.org/html/rfc7231#section-5.5.3
        // Example: `iOS Example/1.0 (org.alamofire.iOS-Example; build:1; iOS 10.0.0) Alamofire/4.0.0`
        let userAgent: String = {
            if let info = Bundle.main.infoDictionary {
                let executable = info[kCFBundleExecutableKey as String] as? String ?? "Unknown"
                let bundle = info[kCFBundleIdentifierKey as String] as? String ?? "Unknown"
                let appVersion = info["CFBundleShortVersionString"] as? String ?? "Unknown"
                let appBuild = info[kCFBundleVersionKey as String] as? String ?? "Unknown"

                let osNameVersion: String = {
                    let version = ProcessInfo.processInfo.operatingSystemVersion
                    let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

                    let osName: String = {
                        #if os(iOS)
                            return "iOS"
                        #elseif os(watchOS)
                            return "watchOS"
                        #elseif os(tvOS)
                            return "tvOS"
                        #elseif os(macOS)
                            return "OS X"
                        #elseif os(Linux)
                            return "Linux"
                        #else
                            return "Unknown"
                        #endif
                    }()

                    return "\(osName) \(versionString)"
                }()

                let alamofireVersion: String = {
                    guard
                        let afInfo = Bundle(for: SessionManager.self).infoDictionary,
                        let build = afInfo["CFBundleShortVersionString"]
                    else { return "Unknown" }

                    return "Alamofire/\(build)"
                }()

                return "\(executable)/\(appVersion) (\(bundle); build:\(appBuild); \(osNameVersion)) \(alamofireVersion)"
            }

            return "Alamofire"
        }()

        return [
            "Accept-Encoding": acceptEncoding,
            "Accept-Language": acceptLanguage,
            "User-Agent": userAgent
        ]
    }()
    /// 设置在编码 MultipartFormData 时的内存使用门限, 单位字节(~10M)
    /// Default memory threshold used when encoding `MultipartFormData` in bytes.
    open static let multipartFormDataEncodingMemoryThreshold: UInt64 = 10_000_000
    /// 内部的 urlsession 对象
    /// The underlying session.
    open let session: URLSession
    /// 会话代理对象, 可以出了所有的任务和会话回调事件
    /// The session delegate handling all the task and session delegate callbacks.
    open let delegate: SessionDelegate
    /// 是否在 request 创建完毕后立即发起请求, 默认为是
    /// Whether to start requests immediately after being constructed. `true` by default.
    open var startRequestsImmediately: Bool = true
    /// 请求适配器, 可以在每次请求创建时, 都会附加一个请求适配器, 可以在其中修改请求
    /// The request adapter called each time a new request is created.
    open var adapter: RequestAdapter?
    /// 重试器, 在请求失败时, 会调用重试器重试请求决定是否需要重新请求一次
    /// The request retrier called each time a request encounters an error to determine whether to retry the request.
    open var retrier: RequestRetrier? {
        get { return delegate.retrier }
        set { delegate.retrier = newValue }
    }
    /// 后台任务结束时的处理器, 由 UIApplicationDelegate 的 `application:handleEventsForBackgroundURLSession:completionHandler:` 所提供, 如果设置了这个处理器, 那么在 SessionDelegate 的 sessionDidFinishEventsForBackgroundURLSession 实现会自动调用这个处理器
    /// 如果你想在这个处理器之气前处理一些自己的事情, 那么你需要覆盖 SessionDelegate 的 sessionDidFinishEventsForBackgroundURLSession 属性, 并在完成时手动调用这个处理器
    /// The background completion handler closure provided by the UIApplicationDelegate
    /// `application:handleEventsForBackgroundURLSession:completionHandler:` method. By setting the background
    /// completion handler, the SessionDelegate `sessionDidFinishEventsForBackgroundURLSession` closure implementation
    /// will automatically call the handler.
    ///
    /// If you need to handle your own events before the handler is called, then you need to override the
    /// SessionDelegate `sessionDidFinishEventsForBackgroundURLSession` and manually call the handler when finished.
    ///
    /// `nil` by default.
    open var backgroundCompletionHandler: (() -> Void)?
    /// 创建一个串行的队列, 用于完成一些需要避免多线程同时修改出错的地方, 例如创建文件夹, 生成 task
    let queue = DispatchQueue(label: "org.alamofire.session-manager." + UUID().uuidString)

    // MARK: - Lifecycle 生命周期
    /// 使用给定的configuration, delegate, serverTrustPolicyManager 创建一个实例
    /// Creates an instance with the specified `configuration`, `delegate` and `serverTrustPolicyManager`.
    ///
    /// - parameter configuration:            The configuration used to construct the managed session. 构造内置的 session 所使用的配置
    ///                                       `URLSessionConfiguration.default` by default.
    /// - parameter delegate:                 The delegate used when initializing the session. `SessionDelegate()` by
    ///                                       default. session 代理
    /// - parameter serverTrustPolicyManager: The server trust policy manager to use for evaluating all server trust
    ///                                       challenges. `nil` by default. 用于管理证书验证
    ///
    /// - returns: The new `SessionManager` instance.
    public init(
        configuration: URLSessionConfiguration = URLSessionConfiguration.default,
        delegate: SessionDelegate = SessionDelegate(),
        serverTrustPolicyManager: ServerTrustPolicyManager? = nil)
    {
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        commonInit(serverTrustPolicyManager: serverTrustPolicyManager)
    }
    /// 使用 session 来初始化一个 manager
    /// Creates an instance with the specified `session`, `delegate` and `serverTrustPolicyManager`.
    ///
    /// - parameter session:                  The URL session.
    /// - parameter delegate:                 The delegate of the URL session. Must equal the URL session's delegate. 需要与 session 内置的代理不同
    /// - parameter serverTrustPolicyManager: The server trust policy manager to use for evaluating all server trust
    ///                                       challenges. `nil` by default.
    ///
    /// - returns: The new `SessionManager` instance if the URL session's delegate matches; `nil` otherwise.
    public init?(
        session: URLSession,
        delegate: SessionDelegate,
        serverTrustPolicyManager: ServerTrustPolicyManager? = nil)
    {
        guard delegate === session.delegate else { return nil }

        self.delegate = delegate
        self.session = session

        commonInit(serverTrustPolicyManager: serverTrustPolicyManager)
    }
    /// 用于完成初始化
    private func commonInit(serverTrustPolicyManager: ServerTrustPolicyManager?) {
        session.serverTrustPolicyManager = serverTrustPolicyManager

        delegate.sessionManager = self

        delegate.sessionDidFinishEventsForBackgroundURLSession = { [weak self] session in
            guard let strongSelf = self else { return }
            DispatchQueue.main.async { strongSelf.backgroundCompletionHandler?() }
        }
    }
    /// 注意, 在销毁对象时, 会同时取消掉所有关联的任务
    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Data Request 数据请求
    /// 创建一个DataRequest 用于接收请求.
    /// Creates a `DataRequest` to retrieve the contents of the specified `url`, `method`, `parameters`, `encoding`
    /// and `headers`.
    ///
    /// - parameter url:        The URL.
    /// - parameter method:     The HTTP method. `.get` by default.
    /// - parameter parameters: The parameters. `nil` by default.
    /// - parameter encoding:   The parameter encoding. `URLEncoding.default` by default.
    /// - parameter headers:    The HTTP headers. `nil` by default.
    ///
    /// - returns: The created `DataRequest`.
    @discardableResult
    open func request(
        _ url: URLConvertible,
        method: HTTPMethod = .get,
        parameters: Parameters? = nil,
        encoding: ParameterEncoding = URLEncoding.default,
        headers: HTTPHeaders? = nil)
        -> DataRequest
    {
        var originalRequest: URLRequest?

        do {
            // 根据 url , header 生成请求
            originalRequest = try URLRequest(url: url, method: method, headers: headers)
            // 编码进去参数
            let encodedURLRequest = try encoding.encode(originalRequest!, with: parameters)
            return request(encodedURLRequest)
        } catch {
            return request(originalRequest, failedWith: error)
        }
    }

    /// Creates a `DataRequest` to retrieve the contents of a URL based on the specified `urlRequest`.
    ///
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter urlRequest: The URL request.
    ///
    /// - returns: The created `DataRequest`.
    open func request(_ urlRequest: URLRequestConvertible) -> DataRequest {
        var originalRequest: URLRequest?

        do {
            // 获取请求
            originalRequest = try urlRequest.asURLRequest()
            // 生成一个 Requestable 结构体, 主要用于后期生成 URLSessionTask
            let originalTask = DataRequest.Requestable(urlRequest: originalRequest!)
            // 使用 adapter 进行适配, 并在 queue 中生成一个 URLSessionTask
            let task = try originalTask.task(session: session, adapter: adapter, queue: queue)
            // 生成一个 Requst 对象
            let request = DataRequest(session: session, requestTask: .data(originalTask, task))
            /// 在session 代理中保存 task 与 request 的关系
            delegate[task] = request
            // 如果需要, 立即启动请求
            if startRequestsImmediately { request.resume() }

            return request
        } catch {
            return request(originalRequest, failedWith: error)
        }
    }

    // MARK: Private - Request Implementation 私有方法, 实现请求错误
    private func request(_ urlRequest: URLRequest?, failedWith error: Error) -> DataRequest {
        /// 生成一个空的 data request
        var requestTask: Request.RequestTask = .data(nil, nil)
        // 如果还有 urlrequest, 那就填进去
        if let urlRequest = urlRequest {
            let originalTask = DataRequest.Requestable(urlRequest: urlRequest)
            requestTask = .data(originalTask, nil)
        }
        // 如果是内部适配器错误, 则将错误置为适配器错误
        let underlyingError = error.underlyingAdaptError ?? error
        // 根据以上信息, 创建一个 requst
        let request = DataRequest(session: session, requestTask: requestTask, error: underlyingError)
        // 如果由重试器, 那么重试??
        //TODO: 确认
        if let retrier = retrier, error is AdaptError {
            allowRetrier(retrier, toRetry: request, with: underlyingError)
        } else {
            // 如果需要, 立即启动请求
            if startRequestsImmediately { request.resume() }
        }

        return request
    }

    // MARK: - Download Request 下载请求

    // MARK: URL Request 整体类似与 datarequest

    /// Creates a `DownloadRequest` to retrieve the contents the specified `url`, `method`, `parameters`, `encoding`,
    /// `headers` and save them to the `destination`.
    ///
    /// If `destination` is not specified, the contents will remain in the temporary location determined by the
    /// underlying URL session.
    /// 如果没有指定下载位置, 文件会被保留在临时位置, 临时位置由内置的 session 决定
    ///
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter url:         The URL.
    /// - parameter method:      The HTTP method. `.get` by default.
    /// - parameter parameters:  The parameters. `nil` by default.
    /// - parameter encoding:    The parameter encoding. `URLEncoding.default` by default.
    /// - parameter headers:     The HTTP headers. `nil` by default.
    /// - parameter destination: The closure used to determine the destination of the downloaded file. `nil` by default.
    ///   下载目标位置 是一个闭包, 会传入临时文件地址以及 httpresponse, 需要返回最终文件地址和写入参数(自动创建文件夹和自动文件覆盖)
    ///
    /// - returns: The created `DownloadRequest`.
    @discardableResult
    open func download(
        _ url: URLConvertible,
        method: HTTPMethod = .get,
        parameters: Parameters? = nil,
        encoding: ParameterEncoding = URLEncoding.default,
        headers: HTTPHeaders? = nil,
        to destination: DownloadRequest.DownloadFileDestination? = nil)
        -> DownloadRequest
    {
        do {
            let urlRequest = try URLRequest(url: url, method: method, headers: headers)
            let encodedURLRequest = try encoding.encode(urlRequest, with: parameters)
            return download(encodedURLRequest, to: destination)
        } catch {
            return download(nil, to: destination, failedWith: error)
        }
    }

    /// Creates a `DownloadRequest` to retrieve the contents of a URL based on the specified `urlRequest` and save
    /// them to the `destination`.
    /// 整体类似与 datarequest
    ///
    /// If `destination` is not specified, the contents will remain in the temporary location determined by the
    /// underlying URL session.
    /// 同上
    ///
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter urlRequest:  The URL request
    /// - parameter destination: The closure used to determine the destination of the downloaded file. `nil` by default. 同上
    ///
    /// - returns: The created `DownloadRequest`.
    @discardableResult
    open func download(
        _ urlRequest: URLRequestConvertible,
        to destination: DownloadRequest.DownloadFileDestination? = nil)
        -> DownloadRequest
    {
        do {
            let urlRequest = try urlRequest.asURLRequest()
            return download(.request(urlRequest), to: destination)
        } catch {
            return download(nil, to: destination, failedWith: error)
        }
    }

    // MARK: Resume Data 断点继续下载

    /// Creates a `DownloadRequest` from the `resumeData` produced from a previous request cancellation to retrieve
    /// the contents of the original request and save them to the `destination`.
    ///
    /// If `destination` is not specified, the contents will remain in the temporary location determined by the
    /// underlying URL session.
    ///
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// 在苹果最近的平台上, 由于一个 bug, 对于一个后台任务, resumeData 总是会被错误的写入, 导致不能被导入, 关于这个bug 的详细情况, 可以参考下面的链接
    /// On the latest release of all the Apple platforms (iOS 10, macOS 10.12, tvOS 10, watchOS 3), `resumeData` is broken
    /// on background URL session configurations. There's an underlying bug in the `resumeData` generation logic where the
    /// data is written incorrectly and will always fail to resume the download. For more information about the bug and
    /// possible workarounds, please refer to the following Stack Overflow post:
    ///
    ///    - http://stackoverflow.com/a/39347461/1342462
    ///
    /// - parameter resumeData:  The resume data. This is an opaque data blob produced by `URLSessionDownloadTask`
    ///                          when a task is cancelled. See `URLSession -downloadTask(withResumeData:)` for
    ///                          additional information.
    /// - parameter destination: The closure used to determine the destination of the downloaded file. `nil` by default.
    ///
    /// - returns: The created `DownloadRequest`.
    @discardableResult
    open func download(
        resumingWith resumeData: Data,
        to destination: DownloadRequest.DownloadFileDestination? = nil)
        -> DownloadRequest
    {
        return download(.resumeData(resumeData), to: destination)
    }

    // MARK: Private - Download Implementation 下载器的实现, 与之前的DataRequest 类似
    private func download(
        _ downloadable: DownloadRequest.Downloadable,
        to destination: DownloadRequest.DownloadFileDestination?)
        -> DownloadRequest
    {
        do {
            let task = try downloadable.task(session: session, adapter: adapter, queue: queue)
            let download = DownloadRequest(session: session, requestTask: .download(downloadable, task))

            download.downloadDelegate.destination = destination

            delegate[task] = download

            if startRequestsImmediately { download.resume() }

            return download
        } catch {
            return download(downloadable, to: destination, failedWith: error)
        }
    }
    /// 同上
    private func download(
        _ downloadable: DownloadRequest.Downloadable?,
        to destination: DownloadRequest.DownloadFileDestination?,
        failedWith error: Error)
        -> DownloadRequest
    {
        var downloadTask: Request.RequestTask = .download(nil, nil)

        if let downloadable = downloadable {
            downloadTask = .download(downloadable, nil)
        }

        let underlyingError = error.underlyingAdaptError ?? error

        let download = DownloadRequest(session: session, requestTask: downloadTask, error: underlyingError)
        download.downloadDelegate.destination = destination

        if let retrier = retrier, error is AdaptError {
            allowRetrier(retrier, toRetry: download, with: underlyingError)
        } else {
            if startRequestsImmediately { download.resume() }
        }

        return download
    }

    // MARK: - Upload Request 上传

    // MARK: File

    /// Creates an `UploadRequest` from the specified `url`, `method` and `headers` for uploading the `file`. 使用指定的 url, 文件 url, method, header 等参数上传
    ///
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter file:    The file to upload.
    /// - parameter url:     The URL.
    /// - parameter method:  The HTTP method. `.post` by default.
    /// - parameter headers: The HTTP headers. `nil` by default.
    ///
    /// - returns: The created `UploadRequest`.
    @discardableResult
    open func upload(
        _ fileURL: URL,
        to url: URLConvertible,
        method: HTTPMethod = .post,
        headers: HTTPHeaders? = nil)
        -> UploadRequest
    {
        do {
            let urlRequest = try URLRequest(url: url, method: method, headers: headers)
            return upload(fileURL, with: urlRequest)
        } catch {
            return upload(nil, failedWith: error)
        }
    }

    /// Creates a `UploadRequest` from the specified `urlRequest` for uploading the `file`.
    /// 同上
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter file:       The file to upload.
    /// - parameter urlRequest: The URL request.
    ///
    /// - returns: The created `UploadRequest`.
    @discardableResult
    open func upload(_ fileURL: URL, with urlRequest: URLRequestConvertible) -> UploadRequest {
        do {
            let urlRequest = try urlRequest.asURLRequest()
            return upload(.file(fileURL, urlRequest))
        } catch {
            return upload(nil, failedWith: error)
        }
    }

    // MARK: Data

    /// Creates an `UploadRequest` from the specified `url`, `method` and `headers` for uploading the `data`.// 直接上传 data
    ///
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter data:    The data to upload.
    /// - parameter url:     The URL.
    /// - parameter method:  The HTTP method. `.post` by default.
    /// - parameter headers: The HTTP headers. `nil` by default.
    ///
    /// - returns: The created `UploadRequest`.
    @discardableResult
    open func upload(
        _ data: Data,
        to url: URLConvertible,
        method: HTTPMethod = .post,
        headers: HTTPHeaders? = nil)
        -> UploadRequest
    {
        do {
            let urlRequest = try URLRequest(url: url, method: method, headers: headers)
            return upload(data, with: urlRequest)
        } catch {
            return upload(nil, failedWith: error)
        }
    }

    /// Creates an `UploadRequest` from the specified `urlRequest` for uploading the `data`.
    /// 同上
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter data:       The data to upload.
    /// - parameter urlRequest: The URL request.
    ///
    /// - returns: The created `UploadRequest`.
    @discardableResult
    open func upload(_ data: Data, with urlRequest: URLRequestConvertible) -> UploadRequest {
        do {
            let urlRequest = try urlRequest.asURLRequest()
            return upload(.data(data, urlRequest))
        } catch {
            return upload(nil, failedWith: error)
        }
    }

    // MARK: InputStream

    /// Creates an `UploadRequest` from the specified `url`, `method` and `headers` for uploading the `stream`.
    /// 使用 inputstream 上传
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter stream:  The stream to upload.
    /// - parameter url:     The URL.
    /// - parameter method:  The HTTP method. `.post` by default.
    /// - parameter headers: The HTTP headers. `nil` by default.
    ///
    /// - returns: The created `UploadRequest`.
    @discardableResult
    open func upload(
        _ stream: InputStream,
        to url: URLConvertible,
        method: HTTPMethod = .post,
        headers: HTTPHeaders? = nil)
        -> UploadRequest
    {
        do {
            let urlRequest = try URLRequest(url: url, method: method, headers: headers)
            return upload(stream, with: urlRequest)
        } catch {
            return upload(nil, failedWith: error)
        }
    }

    /// Creates an `UploadRequest` from the specified `urlRequest` for uploading the `stream`.
    /// 同上
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter stream:     The stream to upload.
    /// - parameter urlRequest: The URL request.
    ///
    /// - returns: The created `UploadRequest`.
    @discardableResult
    open func upload(_ stream: InputStream, with urlRequest: URLRequestConvertible) -> UploadRequest {
        do {
            let urlRequest = try urlRequest.asURLRequest()
            return upload(.stream(stream, urlRequest))
        } catch {
            return upload(nil, failedWith: error)
        }
    }

    // MARK: MultipartFormData

    /// Encodes `multipartFormData` using `encodingMemoryThreshold` and calls `encodingCompletion` with new
    /// `UploadRequest` using the `url`, `method` and `headers`.
    /// 使用 encodingMemoryThreshold 参数编码 multipartFormData, 完成编码后会调用 encodingCompletion 返回一个 UploadRequest
    ///
    /// 理解MultipartFormData 的内存使用是非常重要的. 如果数据量很小, 那么直接在内存中编码, 然后直接上传, 这样效率目前来讲是最高的, 然而, 不过数据列很大, 直接在内存中编码会导致你应用崩溃. 过大的数据必须写入到磁盘, 然后使用输入输出流确保占用内存足够的小, 然后数据就能通过这个文件以流的方式上传. 如果需要上传大数据, 例如视频, 那么必须用流式上传以减少内存占用
    /// encodingMemoryThreshold 参数能让Alamofire 自动决定是要在内存中还是在磁盘中编码解码. 如果数据小于 encodingMemoryThreshold, 那么就直接在内存处理, 否则则在磁盘中处理, 后续的上传过程则根据是否在内存中编码而选择以 Data 方式还是 Stream 方式上传数据.
    /// encodingMemoryThreshold 默认值约为10M
    /// It is important to understand the memory implications of uploading `MultipartFormData`. If the cummulative
    /// payload is small, encoding the data in-memory and directly uploading to a server is the by far the most
    /// efficient approach. However, if the payload is too large, encoding the data in-memory could cause your app to
    /// be terminated. Larger payloads must first be written to disk using input and output streams to keep the memory
    /// footprint low, then the data can be uploaded as a stream from the resulting file. Streaming from disk MUST be
    /// used for larger payloads such as video content.
    ///
    /// The `encodingMemoryThreshold` parameter allows Alamofire to automatically determine whether to encode in-memory
    /// or stream from disk. If the content length of the `MultipartFormData` is below the `encodingMemoryThreshold`,
    /// encoding takes place in-memory. If the content length exceeds the threshold, the data is streamed to disk
    /// during the encoding process. Then the result is uploaded as data or as a stream depending on which encoding
    /// technique was used.
    ///
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter multipartFormData:       The closure used to append body parts to the `MultipartFormData`.
    /// - parameter encodingMemoryThreshold: The encoding memory threshold in bytes.
    ///                                      `multipartFormDataEncodingMemoryThreshold` by default.
    /// - parameter url:                     The URL.
    /// - parameter method:                  The HTTP method. `.post` by default.
    /// - parameter headers:                 The HTTP headers. `nil` by default.
    /// - parameter encodingCompletion:      The closure called when the `MultipartFormData` encoding is complete.
    open func upload(
        multipartFormData: @escaping (MultipartFormData) -> Void,
        usingThreshold encodingMemoryThreshold: UInt64 = SessionManager.multipartFormDataEncodingMemoryThreshold,
        to url: URLConvertible,
        method: HTTPMethod = .post,
        headers: HTTPHeaders? = nil,
        encodingCompletion: ((MultipartFormDataEncodingResult) -> Void)?)
    {
        do {
            let urlRequest = try URLRequest(url: url, method: method, headers: headers)

            return upload(
                multipartFormData: multipartFormData,
                usingThreshold: encodingMemoryThreshold,
                with: urlRequest,
                encodingCompletion: encodingCompletion
            )
        } catch {
            DispatchQueue.main.async { encodingCompletion?(.failure(error)) }
        }
    }

    /// Encodes `multipartFormData` using `encodingMemoryThreshold` and calls `encodingCompletion` with new
    /// `UploadRequest` using the `urlRequest`.
    /// 同上
    ///
    /// It is important to understand the memory implications of uploading `MultipartFormData`. If the cummulative
    /// payload is small, encoding the data in-memory and directly uploading to a server is the by far the most
    /// efficient approach. However, if the payload is too large, encoding the data in-memory could cause your app to
    /// be terminated. Larger payloads must first be written to disk using input and output streams to keep the memory
    /// footprint low, then the data can be uploaded as a stream from the resulting file. Streaming from disk MUST be
    /// used for larger payloads such as video content.
    ///
    /// The `encodingMemoryThreshold` parameter allows Alamofire to automatically determine whether to encode in-memory
    /// or stream from disk. If the content length of the `MultipartFormData` is below the `encodingMemoryThreshold`,
    /// encoding takes place in-memory. If the content length exceeds the threshold, the data is streamed to disk
    /// during the encoding process. Then the result is uploaded as data or as a stream depending on which encoding
    /// technique was used.
    ///
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter multipartFormData:       The closure used to append body parts to the `MultipartFormData`.
    /// - parameter encodingMemoryThreshold: The encoding memory threshold in bytes.
    ///                                      `multipartFormDataEncodingMemoryThreshold` by default.
    /// - parameter urlRequest:              The URL request.
    /// - parameter encodingCompletion:      The closure called when the `MultipartFormData` encoding is complete.
    open func upload(
        multipartFormData: @escaping (MultipartFormData) -> Void,
        usingThreshold encodingMemoryThreshold: UInt64 = SessionManager.multipartFormDataEncodingMemoryThreshold,
        with urlRequest: URLRequestConvertible,
        encodingCompletion: ((MultipartFormDataEncodingResult) -> Void)?)
    {
        DispatchQueue.global(qos: .utility).async {
            //创建一个 formdata
            let formData = MultipartFormData()
            // 根据闭包初始化 form data
            multipartFormData(formData)

            var tempFileURL: URL?

            do {
                var urlRequestWithContentType = try urlRequest.asURLRequest()
                // 设置 contenttype为multipart/form-data; 并在其中加入 boundary
                urlRequestWithContentType.setValue(formData.contentType, forHTTPHeaderField: "Content-Type")

                let isBackgroundSession = self.session.configuration.identifier != nil

                /// 如果不是后台任务, 而且数据量也很小, 那么直接在内存中编码
                if formData.contentLength < encodingMemoryThreshold && !isBackgroundSession {
                    // 编码为 data
                    let data = try formData.encode()
                    // 生成编码结果
                    let encodingResult = MultipartFormDataEncodingResult.success(
                        request: self.upload(data, with: urlRequestWithContentType),
                        streamingFromDisk: false,
                        streamFileURL: nil
                    )
                    // 调用编码结束回调
                    DispatchQueue.main.async { encodingCompletion?(encodingResult) }
                } else {
                    // 需要在硬盘中编码
                    let fileManager = FileManager.default
                    // 获取临时文件夹
                    let tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    // 获取临时数据存放目录
                    let directoryURL = tempDirectoryURL.appendingPathComponent("org.alamofire.manager/multipart.form.data")
                    // 用 uuid生成临时文件名
                    let fileName = UUID().uuidString
                    // 拼接完成最后的文件路径
                    let fileURL = directoryURL.appendingPathComponent(fileName)
                    tempFileURL = fileURL

                    var directoryError: Error?

                    // Create directory inside serial queue to ensure two threads don't do this in parallel
                    // 在一个串行队列中同步执行创建文件夹, 避免多线程时同时执行这段代码
                    self.queue.sync {
                        do {
                            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
                        } catch {
                            directoryError = error
                        }
                    }
                    // 如果创建文件夹出错, 那么抛出异常
                    if let directoryError = directoryError { throw directoryError }
                    /// 写入表单数据到硬盘
                    try formData.writeEncodedData(to: fileURL)
                    /// 获取 uoloadrequest
                    let upload = self.upload(fileURL, with: urlRequestWithContentType)

                    // Cleanup the temp file once the upload is complete
                    // 在上传完成后, 清理临时文件
                    upload.delegate.queue.addOperation {
                        do {
                            try FileManager.default.removeItem(at: fileURL)
                        } catch {
                            // No-op
                        }
                    }

                    DispatchQueue.main.async {
                        /// 生成编码结果
                        let encodingResult = MultipartFormDataEncodingResult.success(
                            request: upload,
                            streamingFromDisk: true,
                            streamFileURL: fileURL
                        )
                        // 回调block 说明编码结果
                        encodingCompletion?(encodingResult)
                    }
                }
            } catch {
                // Cleanup the temp file in the event that the multipart form data encoding failed
                /// 如果发生异常, 则清理临时文件
                if let tempFileURL = tempFileURL {
                    do {
                        try FileManager.default.removeItem(at: tempFileURL)
                    } catch {
                        // No-op
                    }
                }
                // 调用回调指明发生错误
                DispatchQueue.main.async { encodingCompletion?(.failure(error)) }
            }
        }
    }

    // MARK: Private - Upload Implementation
    // 内部函数, 用于生成 uploadrequest
    private func upload(_ uploadable: UploadRequest.Uploadable) -> UploadRequest {
        do {
            // 使用 adapter 生成一个 URLSessionUploadTask
            let task = try uploadable.task(session: session, adapter: adapter, queue: queue)
            // 生成 request 对象
            let upload = UploadRequest(session: session, requestTask: .upload(uploadable, task))

            /// 如果是牛市上传, 则在代理中返回 stream
            if case let .stream(inputStream, _) = uploadable {
                upload.delegate.taskNeedNewBodyStream = { _, _ in inputStream }
            }
            // 绑定代理
            delegate[task] = upload

            if startRequestsImmediately { upload.resume() }

            return upload
        } catch {
            return upload(uploadable, failedWith: error)
        }
    }
    // 内部函数, 用于处理上传错误
    private func upload(_ uploadable: UploadRequest.Uploadable?, failedWith error: Error) -> UploadRequest {
        var uploadTask: Request.RequestTask = .upload(nil, nil)

        if let uploadable = uploadable {
            uploadTask = .upload(uploadable, nil)
        }

        let underlyingError = error.underlyingAdaptError ?? error
        let upload = UploadRequest(session: session, requestTask: uploadTask, error: underlyingError)

        if let retrier = retrier, error is AdaptError {
            allowRetrier(retrier, toRetry: upload, with: underlyingError)
        } else {
            if startRequestsImmediately { upload.resume() }
        }

        return upload
    }

#if !os(watchOS)

    // MARK: - Stream Request
    // 流式请求

    // MARK: Hostname and Port

    /// Creates a `StreamRequest` for bidirectional streaming using the `hostname` and `port`.
    ///
    /// 创建流式请求, 可以和服务器进行双休的数据流交流
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter hostName: The hostname of the server to connect to.
    /// - parameter port:     The port of the server to connect to.
    ///
    /// - returns: The created `StreamRequest`.
    @discardableResult
    @available(iOS 9.0, macOS 10.11, tvOS 9.0, *)
    open func stream(withHostName hostName: String, port: Int) -> StreamRequest {
        return stream(.stream(hostName: hostName, port: port))
    }

    // MARK: NetService

    /// Creates a `StreamRequest` for bidirectional streaming using the `netService`.
    ///
    /// 同上, 使用 NetService 来初始化
    /// If `startRequestsImmediately` is `true`, the request will have `resume()` called before being returned.
    ///
    /// - parameter netService: The net service used to identify the endpoint.
    ///
    /// - returns: The created `StreamRequest`.
    @discardableResult
    @available(iOS 9.0, macOS 10.11, tvOS 9.0, *)
    open func stream(with netService: NetService) -> StreamRequest {
        return stream(.netService(netService))
    }

    // MARK: Private - Stream Implementation
    // 内部函数, 用于生成 StreamRequest
    @available(iOS 9.0, macOS 10.11, tvOS 9.0, *)
    private func stream(_ streamable: StreamRequest.Streamable) -> StreamRequest {
        do {
            /// 生成 URLSessionStreamTask
            let task = try streamable.task(session: session, adapter: adapter, queue: queue)
            // 生成请求对象
            let request = StreamRequest(session: session, requestTask: .stream(streamable, task))

            delegate[task] = request

            if startRequestsImmediately { request.resume() }

            return request
        } catch {
            return stream(failedWith: error)
        }
    }
    // StreamRequest错误处理
    @available(iOS 9.0, macOS 10.11, tvOS 9.0, *)
    private func stream(failedWith error: Error) -> StreamRequest {
        let stream = StreamRequest(session: session, requestTask: .stream(nil, nil), error: error)
        if startRequestsImmediately { stream.resume() }
        return stream
    }

#endif

    // MARK: - Internal - Retry Request
    // 内部函数, 重试请求, 重试成功返回 true
    func retry(_ request: Request) -> Bool {
        guard let originalTask = request.originalTask else { return false }

        do {
            let task = try originalTask.task(session: session, adapter: adapter, queue: queue)

            request.delegate.task = task // resets all task delegate data

            request.retryCount += 1
            request.startTime = CFAbsoluteTimeGetCurrent()
            request.endTime = nil

            task.resume()

            return true
        } catch {
            request.delegate.error = error.underlyingAdaptError ?? error
            return false
        }
    }

    private func allowRetrier(_ retrier: RequestRetrier, toRetry request: Request, with error: Error) {
        DispatchQueue.utility.async { [weak self] in
            guard let strongSelf = self else { return }
            // 调用重试器检查是否需要重试
            retrier.should(strongSelf, retry: request, with: error) { shouldRetry, timeDelay in
                guard let strongSelf = self else { return }
                // 如果需要重试, 那么重试
                guard shouldRetry else {
                    if strongSelf.startRequestsImmediately { request.resume() }
                    return
                }
                // 延迟调用
                DispatchQueue.utility.after(timeDelay) {
                    guard let strongSelf = self else { return }
                    // 检查是否能够重试
                    let retrySucceeded = strongSelf.retry(request)
                    // 如果重试成功, 绑定 delegate
                    if retrySucceeded, let task = request.task {
                        strongSelf.delegate[task] = request
                    } else {
                        // 这里会发生失败
                        if strongSelf.startRequestsImmediately { request.resume() }
                    }
                }
            }
        }
    }
}
