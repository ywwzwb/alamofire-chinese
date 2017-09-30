//
//  MultipartFormData.swift
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

#if os(iOS) || os(watchOS) || os(tvOS)
import MobileCoreServices
#elseif os(macOS)
import CoreServices
#endif

/// Constructs `multipart/form-data` for uploads within an HTTP or HTTPS body. There are currently two ways to encode
/// multipart form data. The first way is to encode the data directly in memory. This is very efficient, but can lead
/// to memory issues if the dataset is too large. The second way is designed for larger datasets and will write all the
/// data to a single file on disk with all the proper boundary segmentation. The second approach MUST be used for
/// larger datasets such as video content, otherwise your app may run out of memory when trying to encode the dataset.
///
/// For more information on `multipart/form-data` in general, please refer to the RFC-2388 and RFC-2045 specs as well
/// and the w3 form documentation.
///
/// - https://www.ietf.org/rfc/rfc2388.txt
/// - https://www.ietf.org/rfc/rfc2045.txt
/// - https://www.w3.org/TR/html401/interact/forms.html#h-17.13
/// 这个类用于处理多表单上传, 目前有两种方法编码
///1. 直接在内存中编码, 非常高效, 但是如果数据量太大的话, 会有内存占用率过高的问题.
///2. 添加合适的分隔符后, 写入磁盘
/// 在处理大数据量时, 必须要采用第二种方式, 否则你的程序会因为编码数据而耗尽内存崩溃
open class MultipartFormData {

    // MARK: - Helper Types
    // 服务类型
    // 定义换行符
    struct EncodingCharacters {
        static let crlf = "\r\n"
    }
    // 生成分隔符的辅助类型
    struct BoundaryGenerator {
        // 分隔符在起始部分, 中间参数分割部分, 以及尾部均不同, 这里使用枚举区分
        enum BoundaryType {
            case initial, encapsulated, final
        }
        // 生成一个随机分隔符
        static func randomBoundary() -> String {
            return String(format: "alamofire.boundary.%08x%08x", arc4random(), arc4random())
        }
        // 根据不同位置, 生成分隔, 并编码处理 data
        static func boundaryData(forBoundaryType boundaryType: BoundaryType, boundary: String) -> Data {
            let boundaryText: String

            switch boundaryType {
            case .initial:
                boundaryText = "--\(boundary)\(EncodingCharacters.crlf)"
            case .encapsulated:
                boundaryText = "\(EncodingCharacters.crlf)--\(boundary)\(EncodingCharacters.crlf)"
            case .final:
                boundaryText = "\(EncodingCharacters.crlf)--\(boundary)--\(EncodingCharacters.crlf)"
            }

            return boundaryText.data(using: String.Encoding.utf8, allowLossyConversion: false)!
        }
    }
    // 请求内容块
    class BodyPart {
        // 头部
        // Content-Disposition: form-data; name="imageName"; filename="imageName.png"
        // Content-Type: image/png
        let headers: HTTPHeaders
        // 内容流
        let bodyStream: InputStream
        // 内容大小
        let bodyContentLength: UInt64
        // 标记是否含有起始分隔
        var hasInitialBoundary = false
        // 标记是否含有结束分隔
        var hasFinalBoundary = false

        init(headers: HTTPHeaders, bodyStream: InputStream, bodyContentLength: UInt64) {
            self.headers = headers
            self.bodyStream = bodyStream
            self.bodyContentLength = bodyContentLength
        }
    }

    // MARK: - Properties

    /// The `Content-Type` header value containing the boundary used to generate the `multipart/form-data`.
    // header 里面的 content type
    open lazy var contentType: String = "multipart/form-data; boundary=\(self.boundary)"

    /// The content length of all body parts used to generate the `multipart/form-data` not including the boundaries.
    // 请求主体中除分隔符之外的数据的大小
    public var contentLength: UInt64 { return bodyParts.reduce(0) { $0 + $1.bodyContentLength } }
    /// 分隔符
    /// The boundary used to separate the body parts in the encoded form data.
    public let boundary: String
    // 内容片段
    private var bodyParts: [BodyPart]
    // 内容片段发生错误, 如无法根据文件 url 获取文件名
    private var bodyPartError: AFError?
    // 流缓冲尺寸
    private let streamBufferSize: Int

    // MARK: - Lifecycle

    /// Creates a multipart form data object.
    ///
    /// - returns: The multipart form data object.
    public init() {
        self.boundary = BoundaryGenerator.randomBoundary()
        self.bodyParts = []

        /// 流读取尺寸
        /// The optimal read/write buffer size in bytes for input and output streams is 1024 (1KB). For more
        /// information, please refer to the following article:
        ///   - https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/Streams/Articles/ReadingInputStreams.html
        ///

        self.streamBufferSize = 1024
    }

    // MARK: - Body Parts

    /// Creates a body part from the data and appends it to the multipart form data object.
    /// 使用 data, name, 构建一个 内容块
    /// The body part data will be encoded using the following format:
    ///
    /// - `Content-Disposition: form-data; name=#{name}` (HTTP Header)
    /// - Encoded data
    /// - Multipart form boundary
    ///
    /// - parameter data: The data to encode into the multipart form data.
    /// - parameter name: The name to associate with the data in the `Content-Disposition` HTTP header.
    public func append(_ data: Data, withName name: String) {
        let headers = contentHeaders(withName: name)
        let stream = InputStream(data: data)
        let length = UInt64(data.count)

        append(stream, withLength: length, headers: headers)
    }

    /// Creates a body part from the data and appends it to the multipart form data object.
    /// 同上
    /// The body part data will be encoded using the following format:
    ///
    /// - `Content-Disposition: form-data; name=#{name}` (HTTP Header)
    /// - `Content-Type: #{generated mimeType}` (HTTP Header)
    /// - Encoded data
    /// - Multipart form boundary
    ///
    /// - parameter data:     The data to encode into the multipart form data.
    /// - parameter name:     The name to associate with the data in the `Content-Disposition` HTTP header.
    /// - parameter mimeType: The MIME type to associate with the data content type in the `Content-Type` HTTP header.
    public func append(_ data: Data, withName name: String, mimeType: String) {
        let headers = contentHeaders(withName: name, mimeType: mimeType)
        let stream = InputStream(data: data)
        let length = UInt64(data.count)

        append(stream, withLength: length, headers: headers)
    }

    /// Creates a body part from the data and appends it to the multipart form data object.
    /// 同上
    /// The body part data will be encoded using the following format:
    ///
    /// - `Content-Disposition: form-data; name=#{name}; filename=#{filename}` (HTTP Header)
    /// - `Content-Type: #{mimeType}` (HTTP Header)
    /// - Encoded file data
    /// - Multipart form boundary
    ///
    /// - parameter data:     The data to encode into the multipart form data.
    /// - parameter name:     The name to associate with the data in the `Content-Disposition` HTTP header.
    /// - parameter fileName: The filename to associate with the data in the `Content-Disposition` HTTP header.
    /// - parameter mimeType: The MIME type to associate with the data in the `Content-Type` HTTP header.
    public func append(_ data: Data, withName name: String, fileName: String, mimeType: String) {
        let headers = contentHeaders(withName: name, fileName: fileName, mimeType: mimeType)
        let stream = InputStream(data: data)
        let length = UInt64(data.count)

        append(stream, withLength: length, headers: headers)
    }

    /// Creates a body part from the file and appends it to the multipart form data object.
    /// 使用文件 url 构建一个 bodypart, 文件名和 contentType 会自动生成
    /// The body part data will be encoded using the following format:
    ///
    /// - `Content-Disposition: form-data; name=#{name}; filename=#{generated filename}` (HTTP Header)
    /// - `Content-Type: #{generated mimeType}` (HTTP Header)
    /// - Encoded file data
    /// - Multipart form boundary
    /// 文件名使用文件 url 的 lastpath 生成, contentType 由系统的 mime 映射表提供
    /// The filename in the `Content-Disposition` HTTP header is generated from the last path component of the
    /// `fileURL`. The `Content-Type` HTTP header MIME type is generated by mapping the `fileURL` extension to the
    /// system associated MIME type.
    ///
    /// - parameter fileURL: The URL of the file whose content will be encoded into the multipart form data.
    /// - parameter name:    The name to associate with the file content in the `Content-Disposition` HTTP header.
    public func append(_ fileURL: URL, withName name: String) {
        let fileName = fileURL.lastPathComponent
        let pathExtension = fileURL.pathExtension
        // 根据文件后缀生成 mime
        if !fileName.isEmpty && !pathExtension.isEmpty {
            let mime = mimeType(forPathExtension: pathExtension)
            append(fileURL, withName: name, fileName: fileName, mimeType: mime)
        } else {
            // 如果读取文件名或者后缀名, 或者 mime 失败, 则报错
            setBodyPartError(withReason: .bodyPartFilenameInvalid(in: fileURL))
        }
    }

    /// Creates a body part from the file and appends it to the multipart form data object.
    /// 根据文件 url, 文件名, mime 生成内容快
    /// The body part data will be encoded using the following format:
    ///
    /// - Content-Disposition: form-data; name=#{name}; filename=#{filename} (HTTP Header)
    /// - Content-Type: #{mimeType} (HTTP Header)
    /// - Encoded file data
    /// - Multipart form boundary
    ///
    /// - parameter fileURL:  The URL of the file whose content will be encoded into the multipart form data.
    /// - parameter name:     The name to associate with the file content in the `Content-Disposition` HTTP header.
    /// - parameter fileName: The filename to associate with the file content in the `Content-Disposition` HTTP header.
    /// - parameter mimeType: The MIME type to associate with the file content in the `Content-Type` HTTP header.
    public func append(_ fileURL: URL, withName name: String, fileName: String, mimeType: String) {
        let headers = contentHeaders(withName: name, fileName: fileName, mimeType: mimeType)

        //============================================================
        //                 Check 1 - is file URL? 检查是否是文件 url
        //============================================================

        guard fileURL.isFileURL else {
            setBodyPartError(withReason: .bodyPartURLInvalid(url: fileURL))
            return
        }

        //============================================================
        //              Check 2 - is file URL reachable? 检查可达性
        //============================================================

        do {
            let isReachable = try fileURL.checkPromisedItemIsReachable()
            guard isReachable else {
                // 不可达
                setBodyPartError(withReason: .bodyPartFileNotReachable(at: fileURL))
                return
            }
        } catch {
            // 测试可达性中发生错误
            setBodyPartError(withReason: .bodyPartFileNotReachableWithError(atURL: fileURL, error: error))
            return
        }

        //============================================================
        //            Check 3 - is file URL a directory? 检查是否是一个文件
        //============================================================

        var isDirectory: ObjCBool = false
        let path = fileURL.path
        
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue else {
            setBodyPartError(withReason: .bodyPartFileIsDirectory(at: fileURL))
            return
        }

        //============================================================
        //          Check 4 - can the file size be extracted? 能否获得文件尺寸
        //============================================================

        let bodyContentLength: UInt64

        do {
            guard let fileSize = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
                setBodyPartError(withReason: .bodyPartFileSizeNotAvailable(at: fileURL))
                return
            }

            bodyContentLength = fileSize.uint64Value
        }
        catch {
            setBodyPartError(withReason: .bodyPartFileSizeQueryFailedWithError(forURL: fileURL, error: error))
            return
        }

        //============================================================
        //       Check 5 - can a stream be created from file URL? 检查是否可以创建一个流
        //============================================================

        guard let stream = InputStream(url: fileURL) else {
            setBodyPartError(withReason: .bodyPartInputStreamCreationFailed(for: fileURL))
            return
        }

        append(stream, withLength: bodyContentLength, headers: headers)
    }

    /// Creates a body part from the stream and appends it to the multipart form data object.
    /// 根据流及相关信息, 创建一个内容快
    /// The body part data will be encoded using the following format:
    ///
    /// - `Content-Disposition: form-data; name=#{name}; filename=#{filename}` (HTTP Header)
    /// - `Content-Type: #{mimeType}` (HTTP Header)
    /// - Encoded stream data
    /// - Multipart form boundary
    ///
    /// - parameter stream:   The input stream to encode in the multipart form data.
    /// - parameter length:   The content length of the stream.
    /// - parameter name:     The name to associate with the stream content in the `Content-Disposition` HTTP header.
    /// - parameter fileName: The filename to associate with the stream content in the `Content-Disposition` HTTP header.
    /// - parameter mimeType: The MIME type to associate with the stream content in the `Content-Type` HTTP header.
    public func append(
        _ stream: InputStream,
        withLength length: UInt64,
        name: String,
        fileName: String,
        mimeType: String)
    {
        let headers = contentHeaders(withName: name, fileName: fileName, mimeType: mimeType)
        append(stream, withLength: length, headers: headers)
    }

    /// Creates a body part with the headers, stream and length and appends it to the multipart form data object.
    /// 同上
    /// The body part data will be encoded using the following format:
    ///
    /// - HTTP headers
    /// - Encoded stream data
    /// - Multipart form boundary
    ///
    /// - parameter stream:  The input stream to encode in the multipart form data.
    /// - parameter length:  The content length of the stream.
    /// - parameter headers: The HTTP headers for the body part.
    public func append(_ stream: InputStream, withLength length: UInt64, headers: HTTPHeaders) {
        let bodyPart = BodyPart(headers: headers, bodyStream: stream, bodyContentLength: length)
        bodyParts.append(bodyPart)
    }

    // MARK: - Data Encoding

    /// Encodes all the appended body parts into a single `Data` value.
    /// 编码整个请求体(在内存中编码)
    /// It is important to note that this method will load all the appended body parts into memory all at the same
    /// time. This method should only be used when the encoded data will have a small memory footprint. For large data
    /// cases, please use the `writeEncodedDataToDisk(fileURL:completionHandler:)` method.
    ///
    /// - throws: An `AFError` if encoding encounters an error.
    ///
    /// - returns: The encoded `Data` if encoding is successful.
    public func encode() throws -> Data {
        // 如果发生异常, 则直接抛出
        if let bodyPartError = bodyPartError {
            throw bodyPartError
        }
        // 最终的请求体
        var encoded = Data()
        // 设置第一段有头, 以及最有一段有尾
        bodyParts.first?.hasInitialBoundary = true
        bodyParts.last?.hasFinalBoundary = true
        // 拼接 body
        for bodyPart in bodyParts {
            // 编码内容块
            let encodedData = try encode(bodyPart)
            // 拼接
            encoded.append(encodedData)
        }

        return encoded
    }

    /// Writes the appended body parts into the given file URL.
    /// 写入编码好的数据到指定文件 url
    /// 适合处理大尺寸数据
    /// This process is facilitated by reading and writing with input and output streams, respectively. Thus,
    /// this approach is very memory efficient and should be used for large body part data.
    ///
    /// - parameter fileURL: The file URL to write the multipart form data into.
    ///
    /// - throws: An `AFError` if encoding encounters an error.
    public func writeEncodedData(to fileURL: URL) throws {
        if let bodyPartError = bodyPartError {
            throw bodyPartError
        }
        // 判断写入文件是否已存在
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw AFError.multipartEncodingFailed(reason: .outputStreamFileAlreadyExists(at: fileURL))
        } else if !fileURL.isFileURL {
            // 判断是否是文件 url
            throw AFError.multipartEncodingFailed(reason: .outputStreamURLInvalid(url: fileURL))
        }
        // 生成流
        guard let outputStream = OutputStream(url: fileURL, append: false) else {
            throw AFError.multipartEncodingFailed(reason: .outputStreamCreationFailed(for: fileURL))
        }
        // 开启流
        outputStream.open()
        defer { outputStream.close() }
        // 设置头尾
        self.bodyParts.first?.hasInitialBoundary = true
        self.bodyParts.last?.hasFinalBoundary = true

        for bodyPart in self.bodyParts {
            // 写入
            try write(bodyPart, to: outputStream)
        }
    }

    // MARK: - Private - Body Part Encoding
    // 编码内容块为 data(在内存中读取并编码)
    private func encode(_ bodyPart: BodyPart) throws -> Data {
        // 最终数据
        var encoded = Data()
        // 如果是第一个数据, 要使用起始字段, 否则用正常分割字段
        let initialData = bodyPart.hasInitialBoundary ? initialBoundaryData() : encapsulatedBoundaryData()
        encoded.append(initialData)
        // 添加头字段
        let headerData = encodeHeaders(for: bodyPart)
        encoded.append(headerData)
        // 添加内容字段
        let bodyStreamData = try encodeBodyStream(for: bodyPart)
        encoded.append(bodyStreamData)
        /// 如果是最后一个数据, 要加上尾字段
        if bodyPart.hasFinalBoundary {
            encoded.append(finalBoundaryData())
        }

        return encoded
    }
    /// 编码头字段: 头示例:
    /// Content-Disposition: form-data; name=#{name}; filename=#{filename}
    /// Content-Type: #{mimeType}
    private func encodeHeaders(for bodyPart: BodyPart) -> Data {
        var headerText = ""
        for (key, value) in bodyPart.headers {
            headerText += "\(key): \(value)\(EncodingCharacters.crlf)"
        }
        headerText += EncodingCharacters.crlf

        return headerText.data(using: String.Encoding.utf8, allowLossyConversion: false)!
    }
    
    /// 编码内容片段(在内存中读取并编码)
    private func encodeBodyStream(for bodyPart: BodyPart) throws -> Data {
        let inputStream = bodyPart.bodyStream
        /// 开启流
        inputStream.open()
        defer { inputStream.close() }
        /// 最终数据
        var encoded = Data()
        /// 读取流
        while inputStream.hasBytesAvailable {
            var buffer = [UInt8](repeating: 0, count: streamBufferSize)
            let bytesRead = inputStream.read(&buffer, maxLength: streamBufferSize)

            if let error = inputStream.streamError {
                throw AFError.multipartEncodingFailed(reason: .inputStreamReadFailed(error: error))
            }

            if bytesRead > 0 {
                encoded.append(buffer, count: bytesRead)
            } else {
                break
            }
        }

        return encoded
    }

    // MARK: - Private - Writing Body Part to Output Stream
    /// 写入编码数据到输出流(硬盘)
    private func write(_ bodyPart: BodyPart, to outputStream: OutputStream) throws {
        /// 写入分隔符
        try writeInitialBoundaryData(for: bodyPart, to: outputStream)
        /// 写入头字段
        try writeHeaderData(for: bodyPart, to: outputStream)
        /// 写入数据
        try writeBodyStream(for: bodyPart, to: outputStream)
        /// 写入结尾字段
        try writeFinalBoundaryData(for: bodyPart, to: outputStream)
    }
    /// 写入分隔符
    private func writeInitialBoundaryData(for bodyPart: BodyPart, to outputStream: OutputStream) throws {
        let initialData = bodyPart.hasInitialBoundary ? initialBoundaryData() : encapsulatedBoundaryData()
        return try write(initialData, to: outputStream)
    }
    /// 写入头字段
    private func writeHeaderData(for bodyPart: BodyPart, to outputStream: OutputStream) throws {
        let headerData = encodeHeaders(for: bodyPart)
        return try write(headerData, to: outputStream)
    }
    /// 写入内容字段
    private func writeBodyStream(for bodyPart: BodyPart, to outputStream: OutputStream) throws {
        let inputStream = bodyPart.bodyStream

        inputStream.open()
        defer { inputStream.close() }
        /// 读取输入流
        while inputStream.hasBytesAvailable {
            /// 设置缓冲区(定义一个数组, 内容全是0)
            var buffer = [UInt8](repeating: 0, count: streamBufferSize)
            /// 读取数据, 并返回实际读取长度
            let bytesRead = inputStream.read(&buffer, maxLength: streamBufferSize)

            if let streamError = inputStream.streamError {
                throw AFError.multipartEncodingFailed(reason: .inputStreamReadFailed(error: streamError))
            }
            /// 如果读取到数据, 那么写进去
            if bytesRead > 0 {
                /// 获取实际读取
                if buffer.count != bytesRead {
                    buffer = Array(buffer[0..<bytesRead])
                }
                /// 写入数据
                try write(&buffer, to: outputStream)
            } else {
                break
            }
        }
    }
    /// 写入尾字段
    private func writeFinalBoundaryData(for bodyPart: BodyPart, to outputStream: OutputStream) throws {
        if bodyPart.hasFinalBoundary {
            return try write(finalBoundaryData(), to: outputStream)
        }
    }

    // MARK: - Private - Writing Buffered Data to Output Stream
    /// 写入 Data数据到输出流
    private func write(_ data: Data, to outputStream: OutputStream) throws {
        var buffer = [UInt8](repeating: 0, count: data.count)
        data.copyBytes(to: &buffer, count: data.count)

        return try write(&buffer, to: outputStream)
    }
    ///写入缓冲区数据到输出流
    private func write(_ buffer: inout [UInt8], to outputStream: OutputStream) throws {
        var bytesToWrite = buffer.count
        /// 如果还有空间, 而且数据不为空
        while bytesToWrite > 0, outputStream.hasSpaceAvailable {
            let bytesWritten = outputStream.write(buffer, maxLength: bytesToWrite)
            if let error = outputStream.streamError {
                throw AFError.multipartEncodingFailed(reason: .outputStreamWriteFailed(error: error))
            }
            /// 获取实际写入的数据长度
            bytesToWrite -= bytesWritten
            /// 截取剩余的数据
            if bytesToWrite > 0 {
                buffer = Array(buffer[bytesWritten..<buffer.count])
            }
        }
    }

    // MARK: - Private - Mime Type
    // 生成 mime
    private func mimeType(forPathExtension pathExtension: String) -> String {
        if
            let id = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, pathExtension as CFString, nil)?.takeRetainedValue(),
            let contentType = UTTypeCopyPreferredTagWithClass(id, kUTTagClassMIMEType)?.takeRetainedValue()
        {
            return contentType as String
        }
        /// 默认的 mime
        return "application/octet-stream"
    }

    // MARK: - Private - Content Headers
    /// 构建获取内容头
    private func contentHeaders(withName name: String, fileName: String? = nil, mimeType: String? = nil) -> [String: String] {
        /// 设置表单的字段名
        var disposition = "form-data; name=\"\(name)\""
        /// 如果有文件名, 加上文件名
        if let fileName = fileName { disposition += "; filename=\"\(fileName)\"" }
        var headers = ["Content-Disposition": disposition]
        /// 如果有 mime ,加上 mime(普通字段不需要)
        if let mimeType = mimeType { headers["Content-Type"] = mimeType }

        return headers
    }

    // MARK: - Private - Boundary Encoding
    /// 获取头分隔符
    private func initialBoundaryData() -> Data {
        return BoundaryGenerator.boundaryData(forBoundaryType: .initial, boundary: boundary)
    }
    /// 获取普通分隔符
    private func encapsulatedBoundaryData() -> Data {
        return BoundaryGenerator.boundaryData(forBoundaryType: .encapsulated, boundary: boundary)
    }
    /// 获取尾分隔符
    private func finalBoundaryData() -> Data {
        return BoundaryGenerator.boundaryData(forBoundaryType: .final, boundary: boundary)
    }

    // MARK: - Private - Errors
    /// 错误处理
    private func setBodyPartError(withReason reason: AFError.MultipartEncodingFailureReason) {
        guard bodyPartError == nil else { return }
        bodyPartError = AFError.multipartEncodingFailed(reason: reason)
    }
}
