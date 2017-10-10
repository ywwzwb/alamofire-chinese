//
//  ParameterEncoding.swift
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

/// HTTP method definitions.
/// http 头的定义
/// See https://tools.ietf.org/html/rfc7231#section-4.3
public enum HTTPMethod: String {
    case options = "OPTIONS"
    case get     = "GET"
    case head    = "HEAD"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
    case trace   = "TRACE"
    case connect = "CONNECT"
}

// MARK: -
/// 参数的类型定义
/// A dictionary of parameters to apply to a `URLRequest`.
public typealias Parameters = [String: Any]

/// A type used to define how a set of parameters are applied to a `URLRequest`.
/// 一个定义如何编码的协议
public protocol ParameterEncoding {
    /// Creates a URL request by encoding parameters and applying them onto an existing request.
    ///
    /// - parameter urlRequest: The request to have parameters applied.
    /// - parameter parameters: The parameters to apply.
    ///
    /// - throws: An `AFError.parameterEncodingFailed` error if encoding fails.
    ///
    /// - returns: The encoded request.
    func encode(_ urlRequest: URLRequestConvertible, with parameters: Parameters?) throws -> URLRequest
}

// MARK: -
/// 生成一个使用url-encoded方式编码过得字符串, 用于设置或是添加到url 或是请求体中, 至于使用何种方式取决于, 却绝育编码的目的地参数
/// Creates a url-encoded query string to be set as or appended to any existing URL query string or set as the HTTP
/// body of the URL request. Whether the query string is set or appended to any existing URL query string or set as
/// the HTTP body depends on the destination of the encoding.
/// http 头中的 Content-Type 字段会被设置为 application/x-www-form-urlencoded; charset=utf-8. 由于没有一个明确的规定如何编码一个集合, 我们这里约定, 对于数组, 我们会在名字后面加上一个中括号[] 如(`foo[]=1&foo[]=2`), 对于字典, 则在中括号中再加入键值, 如foo[bar]=baz
/// The `Content-Type` HTTP header field of an encoded request with HTTP body is set to
/// `application/x-www-form-urlencoded; charset=utf-8`. Since there is no published specification for how to encode
/// collection types, the convention of appending `[]` to the key for array values (`foo[]=1&foo[]=2`), and appending
/// the key surrounded by square brackets for nested dictionary values (`foo[bar]=baz`).
public struct URLEncoding: ParameterEncoding {

    // MARK: Helper Types
    // 辅助类型
    /// 定义编码后的字符串是放到url 还是 请求体中
    /// Defines whether the url-encoded query string is applied to the existing query string or HTTP body of the
    /// resulting URL request.
    ///
    /// methodDependent: 表示视请求类型决定, GET, HEAD, DELETE 放到url 中, 其余放到请求体中
    /// - methodDependent: Applies encoded query string result to existing query string for `GET`, `HEAD` and `DELETE`
    ///                    requests and sets as the HTTP body for requests with any other HTTP method.
    /// - queryString:     Sets or appends encoded query string result to existing query string.
    /// - httpBody:        Sets encoded query string result as the HTTP body of the URL request.
    public enum Destination {
        case methodDependent, queryString, httpBody
    }

    // MARK: Properties
    /// 辅助工厂方法(属性)
    /// Returns a default `URLEncoding` instance.
    /// 使用默认参数, 编码的目的地依据方法而定
    public static var `default`: URLEncoding { return URLEncoding() }
    /// 与 default 相同
    /// Returns a `URLEncoding` instance with a `.methodDependent` destination.
    public static var methodDependent: URLEncoding { return URLEncoding() }
    /// 编码时, 参数直接放到 url 中
    /// Returns a `URLEncoding` instance with a `.queryString` destination.
    public static var queryString: URLEncoding { return URLEncoding(destination: .queryString) }
    /// 编码时, 参数直接放到请求体中
    /// Returns a `URLEncoding` instance with an `.httpBody` destination.
    public static var httpBody: URLEncoding { return URLEncoding(destination: .httpBody) }
    
    ///编码后的参数位置
    /// The destination defining where the encoded query string is to be applied to the URL request.
    public let destination: Destination

    // MARK: Initialization
    /// 构造函数
    /// Creates a `URLEncoding` instance using the specified destination.
    ///
    /// - parameter destination: The destination defining where the encoded query string is to be applied.
    ///
    /// - returns: The new `URLEncoding` instance.
    public init(destination: Destination = .methodDependent) {
        self.destination = destination
    }

    // MARK: Encoding
    /// ParameterEncoding 协议的实现, 编码并设置 request对象
    /// Creates a URL request by encoding parameters and applying them onto an existing request.
    ///
    /// - parameter urlRequest: The request to have parameters applied.
    /// - parameter parameters: The parameters to apply.
    ///
    /// - throws: An `Error` if the encoding process encounters an error.
    ///
    /// - returns: The encoded request.
    ///
    public func encode(_ urlRequest: URLRequestConvertible, with parameters: Parameters?) throws -> URLRequest {
        // 获取 request
        var urlRequest = try urlRequest.asURLRequest()
        // 获取参数, 如果没有参数, 那么直接返回
        guard let parameters = parameters else { return urlRequest }
        // 获取请求方法, 同时, 根据请求方法来判断是否需要编码参数到 url 中
        if let method = HTTPMethod(rawValue: urlRequest.httpMethod ?? "GET"), encodesParametersInURL(with: method) {
            // 直接编码到 url 中
            // 获取 url
            guard let url = urlRequest.url else {
                throw AFError.parameterEncodingFailed(reason: .missingURL)
            }
            // 构建一个URLComponents 对象, 并在其中添加参数
            if var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                // 此处 map 是 optional 的map, 如果 optionvalue 不会空的时候, 会调用 map 内的闭包
                // 如果 url 中本来就有一部分参数了, 那么就将新的参数附加在后面
                let percentEncodedQuery = (urlComponents.percentEncodedQuery.map { $0 + "&" } ?? "") + query(parameters)
                urlComponents.percentEncodedQuery = percentEncodedQuery
                urlRequest.url = urlComponents.url
            }
        } else {
            // 这里是要添加到请求体中
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
            // 编码 body
            urlRequest.httpBody = query(parameters).data(using: .utf8, allowLossyConversion: false)
        }

        return urlRequest
    }
    /// 创建一个使用百分号转义过, 使用 urlencode 编码的键和值, 如果值是一个集合类型, 有可能会有多个返回
    /// Creates percent-escaped, URL encoded query string components from the given key-value pair using recursion.
    ///
    /// - parameter key:   The key of the query component.
    /// - parameter value: The value of the query component.
    ///
    /// - returns: The percent-escaped, URL encoded query string components.
    public func queryComponents(fromKey key: String, value: Any) -> [(String, String)] {
        // 最终结果
        var components: [(String, String)] = []
        /// 如果是字典, 键后面加上[key], 并递归
        if let dictionary = value as? [String: Any] {
            for (nestedKey, value) in dictionary {
                components += queryComponents(fromKey: "\(key)[\(nestedKey)]", value: value)
            }
            // 如果是数组, 键后面加上[]
        } else if let array = value as? [Any] {
            for value in array {
                components += queryComponents(fromKey: "\(key)[]", value: value)
            }
            // 如果是数字
        } else if let value = value as? NSNumber {
            // bool 值的处理
            if value.isBool {
                components.append((escape(key), escape((value.boolValue ? "1" : "0"))))
            } else {
                components.append((escape(key), escape("\(value)")))
            }
            // 如果是 bool 值
        } else if let bool = value as? Bool {
            components.append((escape(key), escape((bool ? "1" : "0"))))
        } else {
            /// 其他值直接输出
            components.append((escape(key), escape("\(value)")))
        }

        return components
    }
    /// 使用百分号转义规则, 转义一个字符串
    /// Returns a percent-escaped string following RFC 3986 for a query string key or value.
    ///
    /// RFC 3986 states that the following characters are "reserved" characters.
    /// 保留字, 即在字符串中不能直接使用的的
    /// - General Delimiters: ":", "#", "[", "]", "@", "?", "/"
    /// - Sub-Delimiters: "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "="
    /// 在 RFC 3986 - $3.4 中, ? 和/ 不应该被转义, 因为一个查询字符串中可能会包含一个 url, 因此, 保留字中 因去掉这两个
    /// In RFC 3986 - Section 3.4, it states that the "?" and "/" characters should not be escaped to allow
    /// query strings to include a URL. Therefore, all "reserved" characters with the exception of "?" and "/"
    /// should be percent-escaped in the query string.
    ///
    /// - parameter string: The string to be percent-escaped.
    ///
    /// - returns: The percent-escaped string.
    public func escape(_ string: String) -> String {
        let generalDelimitersToEncode = ":#[]@" // does not include "?" or "/" due to RFC 3986 - Section 3.4
        let subDelimitersToEncode = "!$&'()*+,;="

        var allowedCharacterSet = CharacterSet.urlQueryAllowed
        allowedCharacterSet.remove(charactersIn: "\(generalDelimitersToEncode)\(subDelimitersToEncode)")

        var escaped = ""

        //==========================================================================================================
        //
        //  Batching is required for escaping due to an internal bug in iOS 8.1 and 8.2. Encoding more than a few
        //  hundred Chinese characters causes various malloc error crashes. To avoid this issue until iOS 8 is no
        //  longer supported, batching MUST be used for encoding. This introduces roughly a 20% overhead. For more
        //  info, please refer to:
        //
        //      - https://github.com/Alamofire/Alamofire/issues/206
        //
        //==========================================================================================================

        if #available(iOS 8.3, *) {
            escaped = string.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet) ?? string
        } else {
            /// 分批解析, 由于 ios8.1 和 8.2 的一个 bug 导致的
            let batchSize = 50
            var index = string.startIndex

            while index != string.endIndex {
                let startIndex = index
                let endIndex = string.index(index, offsetBy: batchSize, limitedBy: string.endIndex) ?? string.endIndex
                let range = startIndex..<endIndex

                let substring = string[range]

                escaped += substring.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet) ?? String(substring)

                index = endIndex
            }
        }

        return escaped
    }
    // 将参数编码为查询字符串
    private func query(_ parameters: [String: Any]) -> String {
        var components: [(String, String)] = []

        for key in parameters.keys.sorted(by: <) {
            let value = parameters[key]!
            components += queryComponents(fromKey: key, value: value)
        }
        return components.map { "\($0)=\($1)" }.joined(separator: "&")
    }
    /// 判断是否要直接在 url 中添加查询字符串
    private func encodesParametersInURL(with method: HTTPMethod) -> Bool {
        /// 如果再目的地中明确指出了, 那么直接返回结果
        switch destination {
        case .queryString:
            return true
        case .httpBody:
            return false
        default:
            break
        }
        /// 如果是依赖方法, 那么就根据不同方法返回不同结果
        switch method {
        case .get, .head, .delete:
            return true
        default:
            return false
        }
    }
}

// MARK: -
/// 使用 json 编码参数
/// Uses `JSONSerialization` to create a JSON representation of the parameters object, which is set as the body of the
/// request. The `Content-Type` HTTP header field of an encoded request is set to `application/json`.
public struct JSONEncoding: ParameterEncoding {

    // MARK: Properties
    ///使用默认参数构造
    /// Returns a `JSONEncoding` instance with default writing options.
    public static var `default`: JSONEncoding { return JSONEncoding() }
    /// 输出 json 时, 格式化内容
    /// Returns a `JSONEncoding` instance with `.prettyPrinted` writing options.
    public static var prettyPrinted: JSONEncoding { return JSONEncoding(options: .prettyPrinted) }
    /// json 输出格式
    /// The options for writing the parameters as JSON data.
    public let options: JSONSerialization.WritingOptions

    // MARK: Initialization

    /// Creates a `JSONEncoding` instance using the specified options.
    ///
    /// - parameter options: The options for writing the parameters as JSON data.
    ///
    /// - returns: The new `JSONEncoding` instance.
    public init(options: JSONSerialization.WritingOptions = []) {
        self.options = options
    }

    // MARK: Encoding
    /// ParameterEncoding 协议实现
    /// Creates a URL request by encoding parameters and applying them onto an existing request.
    ///
    /// - parameter urlRequest: The request to have parameters applied.
    /// - parameter parameters: The parameters to apply.
    ///
    /// - throws: An `Error` if the encoding process encounters an error.
    ///
    /// - returns: The encoded request.
    public func encode(_ urlRequest: URLRequestConvertible, with parameters: Parameters?) throws -> URLRequest {
        var urlRequest = try urlRequest.asURLRequest()

        guard let parameters = parameters else { return urlRequest }

        do {
            /// json 格式化数据
            let data = try JSONSerialization.data(withJSONObject: parameters, options: options)
            /// 设置请求头
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            /// 加上请求体
            urlRequest.httpBody = data
        } catch {
            throw AFError.parameterEncodingFailed(reason: .jsonEncodingFailed(error: error))
        }

        return urlRequest
    }

    /// Creates a URL request by encoding the JSON object and setting the resulting data on the HTTP body.
    /// 实现同上一致, 不过这个可以接受数组的 json
    /// - parameter urlRequest: The request to apply the JSON object to.
    /// - parameter jsonObject: The JSON object to apply to the request.
    ///
    /// - throws: An `Error` if the encoding process encounters an error.
    ///
    /// - returns: The encoded request.
    public func encode(_ urlRequest: URLRequestConvertible, withJSONObject jsonObject: Any? = nil) throws -> URLRequest {
        var urlRequest = try urlRequest.asURLRequest()

        guard let jsonObject = jsonObject else { return urlRequest }

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: options)

            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            urlRequest.httpBody = data
        } catch {
            throw AFError.parameterEncodingFailed(reason: .jsonEncodingFailed(error: error))
        }

        return urlRequest
    }
}

// MARK: -
/// 使用 plist  构造
/// Uses `PropertyListSerialization` to create a plist representation of the parameters object, according to the
/// associated format and write options values, which is set as the body of the request. The `Content-Type` HTTP header
/// field of an encoded request is set to `application/x-plist`.
public struct PropertyListEncoding: ParameterEncoding {

    // MARK: Properties

    /// Returns a default `PropertyListEncoding` instance.
    public static var `default`: PropertyListEncoding { return PropertyListEncoding() }

    /// Returns a `PropertyListEncoding` instance with xml formatting and default writing options.
    public static var xml: PropertyListEncoding { return PropertyListEncoding(format: .xml) }

    /// Returns a `PropertyListEncoding` instance with binary formatting and default writing options.
    public static var binary: PropertyListEncoding { return PropertyListEncoding(format: .binary) }

    /// The property list serialization format.
    public let format: PropertyListSerialization.PropertyListFormat

    /// The options for writing the parameters as plist data.
    public let options: PropertyListSerialization.WriteOptions

    // MARK: Initialization

    /// Creates a `PropertyListEncoding` instance using the specified format and options.
    ///
    /// - parameter format:  The property list serialization format.
    /// - parameter options: The options for writing the parameters as plist data.
    ///
    /// - returns: The new `PropertyListEncoding` instance.
    public init(
        format: PropertyListSerialization.PropertyListFormat = .xml,
        options: PropertyListSerialization.WriteOptions = 0)
    {
        self.format = format
        self.options = options
    }

    // MARK: Encoding

    /// Creates a URL request by encoding parameters and applying them onto an existing request.
    ///
    /// - parameter urlRequest: The request to have parameters applied.
    /// - parameter parameters: The parameters to apply.
    ///
    /// - throws: An `Error` if the encoding process encounters an error.
    ///
    /// - returns: The encoded request.
    public func encode(_ urlRequest: URLRequestConvertible, with parameters: Parameters?) throws -> URLRequest {
        var urlRequest = try urlRequest.asURLRequest()

        guard let parameters = parameters else { return urlRequest }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: parameters,
                format: format,
                options: options
            )

            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
            }

            urlRequest.httpBody = data
        } catch {
            throw AFError.parameterEncodingFailed(reason: .propertyListEncodingFailed(error: error))
        }

        return urlRequest
    }
}

// MARK: -

extension NSNumber {
    fileprivate var isBool: Bool { return CFBooleanGetTypeID() == CFGetTypeID(self) }
}
