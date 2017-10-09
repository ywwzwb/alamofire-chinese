//
//  Request.swift
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
/// 适配器, 适配器可以在请求开始之前, 对请求进行修改
/// A type that can inspect and optionally adapt a `URLRequest` in some manner if necessary.
public protocol RequestAdapter {
    /// 适配器可以在请求开始之前, 执行一段代码, 也可以修改请求, 如果发生错误, 也可以抛出异常
    /// 常用场景为添加认证, token 等
    /// Inspects and adapts the specified `URLRequest` in some manner if necessary and returns the result.
    ///
    /// - parameter urlRequest: The URL request to adapt.
    ///
    /// - throws: An `Error` if the adaptation encounters an error.
    ///
    /// - returns: The adapted `URLRequest`.
    func adapt(_ urlRequest: URLRequest) throws -> URLRequest
}

// MARK: -
/// 请求重试完成的回调函数定义
/// A closure executed when the `RequestRetrier` determines whether a `Request` should be retried or not.
public typealias RequestRetryCompletion = (_ shouldRetry: Bool, _ timeDelay: TimeInterval) -> Void

/// 这个类型定义了某一个请求在发生错误后, 是否应该重试
/// A type that determines whether a request should be retried after being executed by the specified session manager
/// and encountering an error.
public protocol RequestRetrier {
    /// 注意: 决定是否请求, 并不是根据返回值确定的(这个函数返回值为空), 而是有 completion 回调完成的, 里面有一个 should retry 参数.
    /// Determines whether the `Request` should be retried by calling the `completion` closure.
    /// 这个操作是异步的. 你可以花一点时间来决定是否需要重试, 例如登录过期了, 你可能需要尝试重新登录一次 ,这样得要花点时间.
    /// 唯一的要求就是你必须得要调用这个 complete 函数, 以便做一些清理工作
    /// This operation is fully asynchronous. Any amount of time can be taken to determine whether the request needs
    /// to be retried. The one requirement is that the completion closure is called to ensure the request is properly
    /// cleaned up after.
    ///
    /// - parameter manager:    The session manager the request was executed on.
    /// - parameter request:    The request that failed due to the encountered error.
    /// - parameter error:      The error encountered when executing the request.
    /// - parameter completion: The completion closure to be executed when retry decision has been determined.
    func should(_ manager: SessionManager, retry request: Request, with error: Error, completion: @escaping RequestRetryCompletion)
}

// MARK: -
/// 一个可以将某个类型转换为 urlsession task 的协议
protocol TaskConvertible {
    func task(session: URLSession, adapter: RequestAdapter?, queue: DispatchQueue) throws -> URLSessionTask
}
///  http 请求头类型
/// A dictionary of headers to apply to a `URLRequest`.
public typealias HTTPHeaders = [String: String]

// MARK: -
/// 这个类负责发送一个请求, 并且接受请求, 并将数据与服务器关联起来, 同时还管理了内部的 urlsessiontask
/// Responsible for sending a request and receiving the response and associated data from the server, as well as
/// managing its underlying `URLSessionTask`.
open class Request {

    // MARK: Helper Types
    // 辅助类型
    /// 进度处理相关
    /// A closure executed when monitoring upload or download progress of a request.
    public typealias ProgressHandler = (Progress) -> Void
    /// 热舞的几种类型, 对应了 urlsessiontask 的几个子类
    enum RequestTask {
        case data(TaskConvertible?, URLSessionTask?)
        case download(TaskConvertible?, URLSessionTask?)
        case upload(TaskConvertible?, URLSessionTask?)
        case stream(TaskConvertible?, URLSessionTask?)
    }

    // MARK: Properties
    /// 内部 URLSessionTask 的代理, 线程安全的
    /// The delegate for the underlying task.
    open internal(set) var delegate: TaskDelegate {
        get {
            taskDelegateLock.lock() ; defer { taskDelegateLock.unlock() }
            return taskDelegate
        }
        set {
            taskDelegateLock.lock() ; defer { taskDelegateLock.unlock() }
            taskDelegate = newValue
        }
    }
    // 内部的 URLSessionTask
    /// The underlying task.
    open var task: URLSessionTask? { return delegate.task }
    /// URLSession 对象, 和内部的 task 关联
    /// The session belonging to the underlying task.
    open let session: URLSession
    ///  需要发送给服务器的 reqeust
    /// The request sent or to be sent to the server.
    open var request: URLRequest? { return task?.originalRequest }
    /// 服务器的返回
    /// The response received from the server, if any.
    open var response: HTTPURLResponse? { return task?.response as? HTTPURLResponse }
    /// 重试次数
    /// The number of times the request has been retried.
    open internal(set) var retryCount: UInt = 0
    /// 原始任务, 可以用这个生成 URLSessionTask
    let originalTask: TaskConvertible?
    /// 请求启动, 结束时间
    var startTime: CFAbsoluteTime?
    var endTime: CFAbsoluteTime?
    /// 验证器
    var validations: [() -> Void] = []
    /// 代理, 和上面的代理(delegate)是一个东西
    private var taskDelegate: TaskDelegate
    private var taskDelegateLock = NSLock()

    // MARK: Lifecycle
    /// 使用一个 session, 请求任务(内部包含了URLSessionTask, 以及一个 TaskConvertible), 以及错误 创建一个请求
    init(session: URLSession, requestTask: RequestTask, error: Error? = nil) {
        self.session = session
        /// 根据不同的类型, 生成不同的 task delegate
        switch requestTask {
        case .data(let originalTask, let task):
            taskDelegate = DataTaskDelegate(task: task)
            self.originalTask = originalTask
        case .download(let originalTask, let task):
            taskDelegate = DownloadTaskDelegate(task: task)
            self.originalTask = originalTask
        case .upload(let originalTask, let task):
            taskDelegate = UploadTaskDelegate(task: task)
            self.originalTask = originalTask
        case .stream(let originalTask, let task):
            taskDelegate = TaskDelegate(task: task)
            self.originalTask = originalTask
        }
        // 保存错误
        delegate.error = error
        // 在代理的任务队列里面添加一个保存结束时间的闭包
        delegate.queue.addOperation { self.endTime = CFAbsoluteTimeGetCurrent() }
    }

    // MARK: Authentication
    /// 认证
    /// 基础的 http 认证
    /// Associates an HTTP Basic credential with the request.
    ///
    /// - parameter user:        The user. 用户名
    /// - parameter password:    The password. 密码
    /// - parameter persistence: The URL credential persistence. `.ForSession` by default. // 认证的保存时限
    ///
    /// - returns: The request.
    @discardableResult
    open func authenticate(
        user: String,
        password: String,
        persistence: URLCredential.Persistence = .forSession)
        -> Self
    {
        let credential = URLCredential(user: user, password: password, persistence: persistence)
        return authenticate(usingCredential: credential)
    }
    /// 将认证与请求绑定起来
    /// Associates a specified credential with the request.
    ///
    /// - parameter credential: The credential.
    ///
    /// - returns: The request.
    @discardableResult
    open func authenticate(usingCredential credential: URLCredential) -> Self {
        delegate.credential = credential
        return self
    }
    /// 返回一个 base64 编码的基础验证, 用于添加到 http 头里面
    /// Returns a base64 encoded basic authentication credential as an authorization header tuple.
    ///
    /// - parameter user:     The user.
    /// - parameter password: The password.
    ///
    /// - returns: A tuple with Authorization header and credential value if encoding succeeds, `nil` otherwise.
    open static func authorizationHeader(user: String, password: String) -> (key: String, value: String)? {
        guard let data = "\(user):\(password)".data(using: .utf8) else { return nil }

        let credential = data.base64EncodedString(options: [])

        return (key: "Authorization", value: "Basic \(credential)")
    }

    // MARK: State
    // 继续请求
    /// Resumes the request.
    open func resume() {
        // 获取 task, 如果获取失败, 则开始进行任务队列(会抛出错误)
        guard let task = task else { delegate.queue.isSuspended = false ; return }
        //设置启动时间
        if startTime == nil { startTime = CFAbsoluteTimeGetCurrent() }
        // 开始请求
        task.resume()
        // 发送通知
        NotificationCenter.default.post(
            name: Notification.Name.Task.DidResume,
            object: self,
            userInfo: [Notification.Key.Task: task]
        )
    }
    /// 暂停请求
    /// Suspends the request.
    open func suspend() {
        // 如果没有任务, 那么就跳过
        guard let task = task else { return }
        // 暂停
        task.suspend()
        // 发送通知
        NotificationCenter.default.post(
            name: Notification.Name.Task.DidSuspend,
            object: self,
            userInfo: [Notification.Key.Task: task]
        )
    }
    // 取消请求
    /// Cancels the request.
    open func cancel() {
        guard let task = task else { return }
        // 取消
        task.cancel()
        // 发送通知
        NotificationCenter.default.post(
            name: Notification.Name.Task.DidCancel,
            object: self,
            userInfo: [Notification.Key.Task: task]
        )
    }
}

// MARK: - CustomStringConvertible
// 使用 print 时的输出结果
extension Request: CustomStringConvertible {
    // 包含了请求方法与 url , 如果有返回的话, 将返回的状态码也放进去
    /// The textual representation used when written to an output stream, which includes the HTTP method and URL, as
    /// well as the response status code if a response has been received.
    open var description: String {
        var components: [String] = []

        if let HTTPMethod = request?.httpMethod {
            components.append(HTTPMethod)
        }

        if let urlString = request?.url?.absoluteString {
            components.append(urlString)
        }

        if let response = response {
            components.append("(\(response.statusCode))")
        }

        return components.joined(separator: " ")
    }
}

// MARK: - CustomDebugStringConvertible
/// 调试信息, 以 curl 格式展示
extension Request: CustomDebugStringConvertible {
    /// The textual representation used when written to an output stream, in the form of a cURL command.
    open var debugDescription: String {
        return cURLRepresentation()
    }

    func cURLRepresentation() -> String {
        var components = ["$ curl -v"]

        guard let request = self.request,
              let url = request.url,
              let host = url.host
        else {
            return "$ curl command could not be created"
        }

        if let httpMethod = request.httpMethod, httpMethod != "GET" {
            components.append("-X \(httpMethod)")
        }

        if let credentialStorage = self.session.configuration.urlCredentialStorage {
            let protectionSpace = URLProtectionSpace(
                host: host,
                port: url.port ?? 0,
                protocol: url.scheme,
                realm: host,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            )

            if let credentials = credentialStorage.credentials(for: protectionSpace)?.values {
                for credential in credentials {
                    guard let user = credential.user, let password = credential.password else { continue }
                    components.append("-u \(user):\(password)")
                }
            } else {
                if let credential = delegate.credential, let user = credential.user, let password = credential.password {
                    components.append("-u \(user):\(password)")
                }
            }
        }

        if session.configuration.httpShouldSetCookies {
            if
                let cookieStorage = session.configuration.httpCookieStorage,
                let cookies = cookieStorage.cookies(for: url), !cookies.isEmpty
            {
                let string = cookies.reduce("") { $0 + "\($1.name)=\($1.value);" }

            #if swift(>=3.2)
                components.append("-b \"\(string[..<string.index(before: string.endIndex)])\"")
            #else
                components.append("-b \"\(string.substring(to: string.characters.index(before: string.endIndex)))\"")
            #endif
            }
        }

        var headers: [AnyHashable: Any] = [:]

        if let additionalHeaders = session.configuration.httpAdditionalHeaders {
            for (field, value) in additionalHeaders where field != AnyHashable("Cookie") {
                headers[field] = value
            }
        }

        if let headerFields = request.allHTTPHeaderFields {
            for (field, value) in headerFields where field != "Cookie" {
                headers[field] = value
            }
        }

        for (field, value) in headers {
            components.append("-H \"\(field): \(value)\"")
        }

        if let httpBodyData = request.httpBody, let httpBody = String(data: httpBodyData, encoding: .utf8) {
            var escapedBody = httpBody.replacingOccurrences(of: "\\\"", with: "\\\\\"")
            escapedBody = escapedBody.replacingOccurrences(of: "\"", with: "\\\"")

            components.append("-d \"\(escapedBody)\"")
        }

        components.append("\"\(url.absoluteString)\"")

        return components.joined(separator: " \\\n\t")
    }
}

// MARK: - 数据请求

/// Specific type of `Request` that manages an underlying `URLSessionDataTask`.
open class DataRequest: Request {

    // MARK: Helper Types
    /// 辅助类型, 实现TaskConvertible 协议, 用于生成一个 URLSessionDataTask
    struct Requestable: TaskConvertible {
        let urlRequest: URLRequest

        func task(session: URLSession, adapter: RequestAdapter?, queue: DispatchQueue) throws -> URLSessionTask {
            do {
                let urlRequest = try self.urlRequest.adapt(using: adapter)
                return queue.sync { session.dataTask(with: urlRequest) }
            } catch {
                throw AdaptError(error: error)
            }
        }
    }

    // MARK: Properties
    // 获取请求
    /// The request sent or to be sent to the server.
    open override var request: URLRequest? {
        if let request = super.request { return request }
        if let requestable = originalTask as? Requestable { return requestable.urlRequest }

        return nil
    }
    /// 从服务器接收数据的进度
    /// The progress of fetching the response data from the server for the request.
    open var progress: Progress { return dataDelegate.progress }

    var dataDelegate: DataTaskDelegate { return delegate as! DataTaskDelegate }

    // MARK: Stream

    /// Sets a closure to be called periodically during the lifecycle of the request as data is read from the server.
    /// 当从服务器接收到请求时, 这个闭包会被周期性的调用
    /// 这个闭包会返回最近从服务器接收到的数据, 之前的数据会被丢弃
    /// 要注意一点的是, 如果这个闭包被设置, 那么数据就只会传送到这个闭包里面了, 别的地方就不会被存储, 例如 Response 里面的服务器数据将会是空的
    /// This closure returns the bytes most recently received from the server, not including data from previous calls.
    /// If this closure is set, data will only be available within this closure, and will not be saved elsewhere. It is
    /// also important to note that the server data in any `Response` object will be `nil`.
    ///
    /// - parameter closure: The code to be executed periodically during the lifecycle of the request.
    ///
    /// - returns: The request.
    @discardableResult
    open func stream(closure: ((Data) -> Void)? = nil) -> Self {
        dataDelegate.dataStream = closure
        return self
    }

    // MARK: Progress
    
    /// Sets a closure to be called periodically during the lifecycle of the `Request` as data is read from the server.
    /// 当从服务器接收到请求时, 这个闭包会被周期性的调用, 用于告知下载请求的进度
    /// - parameter queue:   The dispatch queue to execute the closure on.
    /// - parameter closure: The code to be executed periodically as data is read from the server.
    ///
    /// - returns: The request.
    @discardableResult
    open func downloadProgress(queue: DispatchQueue = DispatchQueue.main, closure: @escaping ProgressHandler) -> Self {
        dataDelegate.progressHandler = (closure, queue)
        return self
    }
}

// MARK: -

/// Specific type of `Request` that manages an underlying `URLSessionDownloadTask`.
open class DownloadRequest: Request {

    // MARK: Helper Types

    /// A collection of options to be executed prior to moving a downloaded file from the temporary URL to the
    /// destination URL.
    /// 下载时的保存文件的选项
    public struct DownloadOptions: OptionSet {
        /// Returns the raw bitmask value of the option and satisfies the `RawRepresentable` protocol.
        public let rawValue: UInt
        /// 是否会在下载文件路径还不存在的时候, 逐层创建文件夹
        /// A `DownloadOptions` flag that creates intermediate directories for the destination URL if specified.
        public static let createIntermediateDirectories = DownloadOptions(rawValue: 1 << 0)
        /// 是否会在下载文件已经存在的时候, 移除旧有的文件
        /// A `DownloadOptions` flag that removes a previous file from the destination URL if specified.
        public static let removePreviousFile = DownloadOptions(rawValue: 1 << 1)

        /// Creates a `DownloadFileDestinationOptions` instance with the specified raw value.
        ///
        /// - parameter rawValue: The raw bitmask value for the option.
        ///
        /// - returns: A new log level instance.
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }
    }

    /// 当下载请求完成的时候, 这个闭包会被调用一次,用于确定已经完成下载临时文件会被移动到哪里, 这个闭包有两个参数, 第一个参数是临时文件的 url
    /// 另一个参数是返回的请求
    /// 然后返回两个值, 第一个是目标文件的路径, 第二个是保存文件的选项(见上面)
    /// A closure executed once a download request has successfully completed in order to determine where to move the
    /// temporary file written to during the download process. The closure takes two arguments: the temporary file URL
    /// and the URL response, and returns a two arguments: the file URL where the temporary file should be moved and
    /// the options defining how the file should be moved.
    public typealias DownloadFileDestination = (
        _ temporaryURL: URL,
        _ response: HTTPURLResponse)
        -> (destinationURL: URL, options: DownloadOptions)
    
    ///实现 TaskConvertible , 用于生成 URLSessionTask
    /// 这里有两种方式生成, 一种是使用 request ,一种是使用 resumedata
    enum Downloadable: TaskConvertible {
        case request(URLRequest)
        case resumeData(Data)

        func task(session: URLSession, adapter: RequestAdapter?, queue: DispatchQueue) throws -> URLSessionTask {
            do {
                let task: URLSessionTask

                switch self {
                case let .request(urlRequest):
                    let urlRequest = try urlRequest.adapt(using: adapter)
                    task = queue.sync { session.downloadTask(with: urlRequest) }
                case let .resumeData(resumeData):
                    task = queue.sync { session.downloadTask(withResumeData: resumeData) }
                }

                return task
            } catch {
                throw AdaptError(error: error)
            }
        }
    }

    // MARK: Properties

    /// The request sent or to be sent to the server.
    open override var request: URLRequest? {
        if let request = super.request { return request }

        if let downloadable = originalTask as? Downloadable, case let .request(urlRequest) = downloadable {
            return urlRequest
        }

        return nil
    }

    /// The resume data of the underlying download task if available after a failure.
    open var resumeData: Data? { return downloadDelegate.resumeData }

    /// The progress of downloading the response data from the server for the request.
    open var progress: Progress { return downloadDelegate.progress }

    var downloadDelegate: DownloadTaskDelegate { return delegate as! DownloadTaskDelegate }

    // MARK: State

    /// Cancels the request.
    /// 取消请求, 会存储断点续传的数据
    open override func cancel() {
        downloadDelegate.downloadTask.cancel { self.downloadDelegate.resumeData = $0 }

        NotificationCenter.default.post(
            name: Notification.Name.Task.DidCancel,
            object: self,
            userInfo: [Notification.Key.Task: task as Any]
        )
    }

    // MARK: Progress

    /// Sets a closure to be called periodically during the lifecycle of the `Request` as data is read from the server.
    ///
    /// - parameter queue:   The dispatch queue to execute the closure on.
    /// - parameter closure: The code to be executed periodically as data is read from the server.
    ///
    /// - returns: The request.
    @discardableResult
    open func downloadProgress(queue: DispatchQueue = DispatchQueue.main, closure: @escaping ProgressHandler) -> Self {
        downloadDelegate.progressHandler = (closure, queue)
        return self
    }

    // MARK: Destination
    /// 用于便捷生成下载目的地
    /// Creates a download file destination closure which uses the default file manager to move the temporary file to a
    /// file URL in the first available directory with the specified search path directory and search path domain mask.
    ///
    /// - parameter directory: The search path directory. `.DocumentDirectory` by default.
    /// - parameter domain:    The search path domain mask. `.UserDomainMask` by default.
    ///
    /// - returns: A download file destination closure.
    open class func suggestedDownloadDestination(
        for directory: FileManager.SearchPathDirectory = .documentDirectory,
        in domain: FileManager.SearchPathDomainMask = .userDomainMask)
        -> DownloadFileDestination
    {
        return { temporaryURL, response in
            let directoryURLs = FileManager.default.urls(for: directory, in: domain)

            if !directoryURLs.isEmpty {
                return (directoryURLs[0].appendingPathComponent(response.suggestedFilename!), [])
            }

            return (temporaryURL, [])
        }
    }
}

// MARK: -

/// Specific type of `Request` that manages an underlying `URLSessionUploadTask`.
open class UploadRequest: DataRequest {

    // MARK: Helper Types
    // 用于生成 urlsessiontask, 可以使用数据, 文件, 流 三种方式生成 task
    enum Uploadable: TaskConvertible {
        case data(Data, URLRequest)
        case file(URL, URLRequest)
        case stream(InputStream, URLRequest)

        func task(session: URLSession, adapter: RequestAdapter?, queue: DispatchQueue) throws -> URLSessionTask {
            do {
                let task: URLSessionTask

                switch self {
                case let .data(data, urlRequest):
                    let urlRequest = try urlRequest.adapt(using: adapter)
                    task = queue.sync { session.uploadTask(with: urlRequest, from: data) }
                case let .file(url, urlRequest):
                    let urlRequest = try urlRequest.adapt(using: adapter)
                    task = queue.sync { session.uploadTask(with: urlRequest, fromFile: url) }
                case let .stream(_, urlRequest):
                    let urlRequest = try urlRequest.adapt(using: adapter)
                    task = queue.sync { session.uploadTask(withStreamedRequest: urlRequest) }
                }

                return task
            } catch {
                throw AdaptError(error: error)
            }
        }
    }

    // MARK: Properties

    /// The request sent or to be sent to the server.
    open override var request: URLRequest? {
        if let request = super.request { return request }

        guard let uploadable = originalTask as? Uploadable else { return nil }

        switch uploadable {
        case .data(_, let urlRequest), .file(_, let urlRequest), .stream(_, let urlRequest):
            return urlRequest
        }
    }

    /// The progress of uploading the payload to the server for the upload request.
    open var uploadProgress: Progress { return uploadDelegate.uploadProgress }

    var uploadDelegate: UploadTaskDelegate { return delegate as! UploadTaskDelegate }

    // MARK: Upload Progress

    /// Sets a closure to be called periodically during the lifecycle of the `UploadRequest` as data is sent to
    /// the server.
    ///
    /// After the data is sent to the server, the `progress(queue:closure:)` APIs can be used to monitor the progress
    /// of data being read from the server.
    ///
    /// - parameter queue:   The dispatch queue to execute the closure on.
    /// - parameter closure: The code to be executed periodically as data is sent to the server.
    ///
    /// - returns: The request.
    @discardableResult
    open func uploadProgress(queue: DispatchQueue = DispatchQueue.main, closure: @escaping ProgressHandler) -> Self {
        uploadDelegate.uploadProgressHandler = (closure, queue)
        return self
    }
}

// MARK: -

#if !os(watchOS)

/// Specific type of `Request` that manages an underlying `URLSessionStreamTask`.
@available(iOS 9.0, macOS 10.11, tvOS 9.0, *)
open class StreamRequest: Request {
    enum Streamable: TaskConvertible {
        case stream(hostName: String, port: Int)
        case netService(NetService)

        func task(session: URLSession, adapter: RequestAdapter?, queue: DispatchQueue) throws -> URLSessionTask {
            let task: URLSessionTask

            switch self {
            case let .stream(hostName, port):
                task = queue.sync { session.streamTask(withHostName: hostName, port: port) }
            case let .netService(netService):
                task = queue.sync { session.streamTask(with: netService) }
            }

            return task
        }
    }
}

#endif
