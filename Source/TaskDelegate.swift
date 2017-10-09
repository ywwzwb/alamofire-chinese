//
//  TaskDelegate.swift
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

/// task delegate 负责处理所有内部的urlsessiontask 的代理回调, 同时在任务结束时, 执行所有的附加操作.
/// The task delegate is responsible for handling all delegate callbacks for the underlying task as well as
/// executing all operations attached to the serial operation queue upon task completion.
open class TaskDelegate: NSObject {

    // MARK: Properties
    /// 操作队列, 用于在任务完成时, 执行附加的操作
    /// The serial operation queue used to execute all operations after the task completes.
    open let queue: OperationQueue
    /// 服务器返回的数据
    /// The data returned by the server.
    public var data: Data? { return nil }
    /// 在这个任务执行期间发生的错误
    /// The error generated throughout the lifecyle of the task.
    public var error: Error?
    /// 内部的 urlsessiontask, 现成安全
    var task: URLSessionTask? {
        set {
            taskLock.lock(); defer { taskLock.unlock() }
            _task = newValue
        }
        get {
            taskLock.lock(); defer { taskLock.unlock() }
            return _task
        }
    }
    /// 接收到相应的时间
    var initialResponseTime: CFAbsoluteTime?
    /// 验证用的证书
    var credential: URLCredential?
    var metrics: AnyObject? // URLSessionTaskMetrics
    
    private var _task: URLSessionTask? {
        didSet { reset() }
    }
    
    private let taskLock = NSLock()

    // MARK: Lifecycle
    
    init(task: URLSessionTask?) {
        _task = task
        // 创建 operation queue, 用于完成后的链式处理
        self.queue = {
            let operationQueue = OperationQueue()
            // 串行的
            operationQueue.maxConcurrentOperationCount = 1
            // 初始状态是停止额
            operationQueue.isSuspended = true
            operationQueue.qualityOfService = .utility

            return operationQueue
        }()
    }

    func reset() {
        error = nil
        initialResponseTime = nil
    }

    // MARK: URLSessionTaskDelegate

    var taskWillPerformHTTPRedirection: ((URLSession, URLSessionTask, HTTPURLResponse, URLRequest) -> URLRequest?)?
    var taskDidReceiveChallenge: ((URLSession, URLSessionTask, URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    var taskNeedNewBodyStream: ((URLSession, URLSessionTask) -> InputStream?)?
    var taskDidCompleteWithError: ((URLSession, URLSessionTask, Error?) -> Void)?
    // 重定向
    @objc(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void)
    {
        var redirectRequest: URLRequest? = request

        if let taskWillPerformHTTPRedirection = taskWillPerformHTTPRedirection {
            redirectRequest = taskWillPerformHTTPRedirection(session, task, response, request)
        }

        completionHandler(redirectRequest)
    }
    // 证书验证
    @objc(URLSession:task:didReceiveChallenge:completionHandler:)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
        var credential: URLCredential?

        if let taskDidReceiveChallenge = taskDidReceiveChallenge {
            (disposition, credential) = taskDidReceiveChallenge(session, task, challenge)
        } else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // 默认处理
            let host = challenge.protectionSpace.host

            if
                let serverTrustPolicy = session.serverTrustPolicyManager?.serverTrustPolicy(forHost: host),
                let serverTrust = challenge.protectionSpace.serverTrust
            {
                if serverTrustPolicy.evaluate(serverTrust, forHost: host) {
                    disposition = .useCredential
                    credential = URLCredential(trust: serverTrust)
                } else {
                    disposition = .cancelAuthenticationChallenge
                }
            }
        } else {
            if challenge.previousFailureCount > 0 {
                disposition = .rejectProtectionSpace
            } else {
                credential = self.credential ?? session.configuration.urlCredentialStorage?.defaultCredential(for: challenge.protectionSpace)

                if credential != nil {
                    disposition = .useCredential
                }
            }
        }

        completionHandler(disposition, credential)
    }
    /// 需要新内容
    @objc(URLSession:task:needNewBodyStream:)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void)
    {
        var bodyStream: InputStream?

        if let taskNeedNewBodyStream = taskNeedNewBodyStream {
            bodyStream = taskNeedNewBodyStream(session, task)
        }

        completionHandler(bodyStream)
    }
    /// 请求完成
    @objc(URLSession:task:didCompleteWithError:)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let taskDidCompleteWithError = taskDidCompleteWithError {
            taskDidCompleteWithError(session, task, error)
        } else {
            if let error = error {
                // 发生错误
                if self.error == nil { self.error = error }

                // 如果是下载请求, 将 resume data 保存一下
                if
                    let downloadDelegate = self as? DownloadTaskDelegate,
                    let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                {
                    downloadDelegate.resumeData = resumeData
                }
            }
            // 请求结束, 开始任务队列
            queue.isSuspended = false
        }
    }
}

// MARK: -
//
class DataTaskDelegate: TaskDelegate, URLSessionDataDelegate {

    // MARK: Properties

    var dataTask: URLSessionDataTask { return task as! URLSessionDataTask }

    override var data: Data? {
        if dataStream != nil {
            return nil
        } else {
            return mutableData
        }
    }
    //进度信息
    var progress: Progress
    // 自定义的任务处理回调
    var progressHandler: (closure: Request.ProgressHandler, queue: DispatchQueue)?

    var dataStream: ((_ data: Data) -> Void)?

    private var totalBytesReceived: Int64 = 0
    private var mutableData: Data

    private var expectedContentLength: Int64?

    // MARK: Lifecycle

    override init(task: URLSessionTask?) {
        mutableData = Data()
        progress = Progress(totalUnitCount: 0)

        super.init(task: task)
    }

    override func reset() {
        super.reset()

        progress = Progress(totalUnitCount: 0)
        totalBytesReceived = 0
        mutableData = Data()
        expectedContentLength = nil
    }

    // MARK: URLSessionDataDelegate

    var dataTaskDidReceiveResponse: ((URLSession, URLSessionDataTask, URLResponse) -> URLSession.ResponseDisposition)?
    var dataTaskDidBecomeDownloadTask: ((URLSession, URLSessionDataTask, URLSessionDownloadTask) -> Void)?
    var dataTaskDidReceiveData: ((URLSession, URLSessionDataTask, Data) -> Void)?
    var dataTaskWillCacheResponse: ((URLSession, URLSessionDataTask, CachedURLResponse) -> CachedURLResponse?)?
    // 接收到请求
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    {
        // 设置允许请求
        var disposition: URLSession.ResponseDisposition = .allow
        // 获取内容长度(根据 response header)
        expectedContentLength = response.expectedContentLength
        // 如果由自定义回调, 执行
        if let dataTaskDidReceiveResponse = dataTaskDidReceiveResponse {
            disposition = dataTaskDidReceiveResponse(session, dataTask, response)
        }
        // 继续请求
        completionHandler(disposition)
    }
    // 请求变更为下载请求的情况
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didBecome downloadTask: URLSessionDownloadTask)
    {
        dataTaskDidBecomeDownloadTask?(session, dataTask, downloadTask)
    }
    // 接收到服务器的数据
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // 记录接收到数据的时间
        if initialResponseTime == nil { initialResponseTime = CFAbsoluteTimeGetCurrent() }
        // 如果由自定义回调, 执行自定义回调
        if let dataTaskDidReceiveData = dataTaskDidReceiveData {
            dataTaskDidReceiveData(session, dataTask, data)
        } else {
            // 如果由自定义的 datastream 处理 ,将接收到的数据穿进去
            if let dataStream = dataStream {
                dataStream(data)
            } else {
                // 否则保存数据
                mutableData.append(data)
            }
            // 获取数据长度
            let bytesReceived = Int64(data.count)
            // 记录已接收的数据长度
            totalBytesReceived += bytesReceived
            // 获取预计长度
            let totalBytesExpected = dataTask.response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown
            // 更新进度
            progress.totalUnitCount = totalBytesExpected
            progress.completedUnitCount = totalBytesReceived
            // 如果有自定义的进度处理回调, 执行
            if let progressHandler = progressHandler {
                progressHandler.queue.async { progressHandler.closure(self.progress) }
            }
        }
    }
    // 将要缓存数据
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void)
    {
        var cachedResponse: CachedURLResponse? = proposedResponse

        if let dataTaskWillCacheResponse = dataTaskWillCacheResponse {
            // 如果由自定义, 则暗自定义的缓存策略, 否则默认(根据 session config, response header 等决定)
            cachedResponse = dataTaskWillCacheResponse(session, dataTask, proposedResponse)
        }

        completionHandler(cachedResponse)
    }
}

// MARK: -

class DownloadTaskDelegate: TaskDelegate, URLSessionDownloadDelegate {

    // MARK: Properties
    
    var downloadTask: URLSessionDownloadTask { return task as! URLSessionDownloadTask }

    var progress: Progress
    var progressHandler: (closure: Request.ProgressHandler, queue: DispatchQueue)?

    var resumeData: Data?
    override var data: Data? { return resumeData }

    var destination: DownloadRequest.DownloadFileDestination?

    var temporaryURL: URL?
    var destinationURL: URL?

    var fileURL: URL? { return destination != nil ? destinationURL : temporaryURL }

    // MARK: Lifecycle

    override init(task: URLSessionTask?) {
        progress = Progress(totalUnitCount: 0)
        super.init(task: task)
    }

    override func reset() {
        super.reset()

        progress = Progress(totalUnitCount: 0)
        resumeData = nil
    }

    // MARK: URLSessionDownloadDelegate

    var downloadTaskDidFinishDownloadingToURL: ((URLSession, URLSessionDownloadTask, URL) -> URL)?
    var downloadTaskDidWriteData: ((URLSession, URLSessionDownloadTask, Int64, Int64, Int64) -> Void)?
    var downloadTaskDidResumeAtOffset: ((URLSession, URLSessionDownloadTask, Int64, Int64) -> Void)?

    /// 下载完成
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL)
    {
        temporaryURL = location

        guard
            let destination = destination,
            let response = downloadTask.response as? HTTPURLResponse
        else { return }
        // 获取下载目的地
        let result = destination(location, response)
        let destinationURL = result.destinationURL
        let options = result.options
        // 保存下载目的地
        self.destinationURL = destinationURL

        do {
            /// 如果需要移除旧文件, 那么在这里移除
            if options.contains(.removePreviousFile), FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            // 如果需要创建文件夹, 那么久创建
            if options.contains(.createIntermediateDirectories) {
                let directory = destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            // 完成之后, 移动文件到制定位置
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            self.error = error
        }
    }

    /// 写入文件进度信息
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64)
    {
        if initialResponseTime == nil { initialResponseTime = CFAbsoluteTimeGetCurrent() }

        if let downloadTaskDidWriteData = downloadTaskDidWriteData {
            downloadTaskDidWriteData(
                session,
                downloadTask,
                bytesWritten,
                totalBytesWritten,
                totalBytesExpectedToWrite
            )
        } else {
            progress.totalUnitCount = totalBytesExpectedToWrite
            progress.completedUnitCount = totalBytesWritten

            if let progressHandler = progressHandler {
                progressHandler.queue.async { progressHandler.closure(self.progress) }
            }
        }
    }
    // 断点续传
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64)
    {
        if let downloadTaskDidResumeAtOffset = downloadTaskDidResumeAtOffset {
            downloadTaskDidResumeAtOffset(session, downloadTask, fileOffset, expectedTotalBytes)
        } else {
            progress.totalUnitCount = expectedTotalBytes
            progress.completedUnitCount = fileOffset
        }
    }
}

// MARK: -

class UploadTaskDelegate: DataTaskDelegate {

    // MARK: Properties

    var uploadTask: URLSessionUploadTask { return task as! URLSessionUploadTask }

    var uploadProgress: Progress
    var uploadProgressHandler: (closure: Request.ProgressHandler, queue: DispatchQueue)?

    // MARK: Lifecycle

    override init(task: URLSessionTask?) {
        uploadProgress = Progress(totalUnitCount: 0)
        super.init(task: task)
    }

    override func reset() {
        super.reset()
        uploadProgress = Progress(totalUnitCount: 0)
    }

    // MARK: URLSessionTaskDelegate

    var taskDidSendBodyData: ((URLSession, URLSessionTask, Int64, Int64, Int64) -> Void)?

    func URLSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64)
    {
        if initialResponseTime == nil { initialResponseTime = CFAbsoluteTimeGetCurrent() }

        if let taskDidSendBodyData = taskDidSendBodyData {
            taskDidSendBodyData(session, task, bytesSent, totalBytesSent, totalBytesExpectedToSend)
        } else {
            uploadProgress.totalUnitCount = totalBytesExpectedToSend
            uploadProgress.completedUnitCount = totalBytesSent

            if let uploadProgressHandler = uploadProgressHandler {
                uploadProgressHandler.queue.async { uploadProgressHandler.closure(self.uploadProgress) }
            }
        }
    }
}
