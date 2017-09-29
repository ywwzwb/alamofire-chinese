//
//  NetworkReachabilityManager.swift
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

#if !os(watchOS)

import Foundation
import SystemConfiguration
/// 这个类会监听对制定/地址的网络可达性的变化, 在移动网络(wwan) 和 wifi 下都能正常使用
/// The `NetworkReachabilityManager` class listens for reachability changes of hosts and addresses for both WWAN and
/// WiFi network interfaces.
///
/// Reachability(可达性)可以在确定网络失败原因时作为一个基础信息, 或者是当网络链接建立的时候, 重试请求.
/// 不应被用于阻止用户进行某个请求, 因为有可能需要简历一个厨师请求来判断网络可达性
/// Reachability can be used to determine background information about why a network operation failed, or to retry
/// network requests when a connection is established. It should not be used to prevent a user from initiating a network
/// request, as it's possible that an initial request may be required to establish reachability.
public class NetworkReachabilityManager {
    /// 定义了网络可达性类型
    /// Defines the various states of network reachability.
    ///
    /// - unknown:      It is unknown whether the network is reachable. 未知的, 不清楚网络是否可达
    /// - notReachable: The network is not reachable. 不可达
    /// - reachable:    The network is reachable. 可达
    public enum NetworkReachabilityStatus {
        case unknown
        case notReachable
        case reachable(ConnectionType)
    }
    /// 定义了网络连接类型
    /// Defines the various connection types detected by reachability flags.
    ///
    /// - ethernetOrWiFi: The connection type is either over Ethernet or WiFi. 通过以太网(网线) 或者 wifi 连接
    /// - wwan:           The connection type is a WWAN connection.  通过移动网络
    public enum ConnectionType {
        case ethernetOrWiFi
        case wwan
    }
    /// 监听器类型, 实质是一个闭包, 当网络状态改变时, 闭包会被调用, 闭包有一个参数, 为网络可达性状态
    /// A closure executed when the network reachability status changes. The closure takes a single argument: the
    /// network reachability status.
    public typealias Listener = (NetworkReachabilityStatus) -> Void

    // MARK: - Properties
    /// 一些便利属性
    /// 是否可达
    /// Whether the network is currently reachable.
    public var isReachable: Bool { return isReachableOnWWAN || isReachableOnEthernetOrWiFi }
    /// 是否可达, 且同过移动网络访问
    /// Whether the network is currently reachable over the WWAN interface.
    public var isReachableOnWWAN: Bool { return networkReachabilityStatus == .reachable(.wwan) }
    /// 是否可达, 且通过 wifi 或者以太网访问
    /// Whether the network is currently reachable over Ethernet or WiFi interface.
    public var isReachableOnEthernetOrWiFi: Bool { return networkReachabilityStatus == .reachable(.ethernetOrWiFi) }
    /// 目前的网络可达性
    /// The current network reachability status.
    public var networkReachabilityStatus: NetworkReachabilityStatus {
        guard let flags = self.flags else { return .unknown }
        return networkReachabilityStatusForFlags(flags)
    }
    /// 监听器中代码执行所在的队列, 默认为主队列
    /// The dispatch queue to execute the `listener` closure on.
    public var listenerQueue: DispatchQueue = DispatchQueue.main
    /// 监听器, 在网络状态发生变化时会调用
    /// A closure executed when the network reachability status changes.
    public var listener: Listener?
    /// 状态码
    private var flags: SCNetworkReachabilityFlags? {
        var flags = SCNetworkReachabilityFlags()

        if SCNetworkReachabilityGetFlags(reachability, &flags) {
            return flags
        }

        return nil
    }
    /// 可达性
    private let reachability: SCNetworkReachability
    /// 上一个状态
    private var previousFlags: SCNetworkReachabilityFlags

    // MARK: - Initialization
    /// 便利构造函数, 通过传入一个主机地址, 验证可达性
    /// Creates a `NetworkReachabilityManager` instance with the specified host.
    ///
    /// - parameter host: The host used to evaluate network reachability.
    ///
    /// - returns: The new `NetworkReachabilityManager` instance.
    public convenience init?(host: String) {
        guard let reachability = SCNetworkReachabilityCreateWithName(nil, host) else { return nil }
        self.init(reachability: reachability)
    }
    /// 依靠监听0.0.0.0 来构造
    /// Creates a `NetworkReachabilityManager` instance that monitors the address 0.0.0.0.
    /// 可达性将0.0.0.0 视为一个特殊的地址, 因为他会监听设备的路由信息, 在 ipv4 和 ipv6 下都可以使用
    /// Reachability treats the 0.0.0.0 address as a special token that causes it to monitor the general routing
    /// status of the device, both IPv4 and IPv6.
    ///
    /// - returns: The new `NetworkReachabilityManager` instance.
    public convenience init?() {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)

        guard let reachability = withUnsafePointer(to: &address, { pointer in
            return pointer.withMemoryRebound(to: sockaddr.self, capacity: MemoryLayout<sockaddr>.size) {
                return SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }) else { return nil }

        self.init(reachability: reachability)
    }
    /// 构造函数, 通过 SCNetworkReachability 来构造
    private init(reachability: SCNetworkReachability) {
        self.reachability = reachability
        self.previousFlags = SCNetworkReachabilityFlags()
    }
    /// 注意的是, 在析构的时候, 将会停止监听网络变化
    deinit {
        stopListening()
    }

    // MARK: - Listening
    /// 开始监听网络状况, 启动失败会返回 false
    /// Starts listening for changes in network reachability status.
    ///
    /// - returns: `true` if listening was started successfully, `false` otherwise.
    @discardableResult
    public func startListening() -> Bool {
        /// 设置上下文
        var context = SCNetworkReachabilityContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        // 注册回调函数
        let callbackEnabled = SCNetworkReachabilitySetCallback(
            reachability,
            { (_, flags, info) in
                // 获取 self
                let reachability = Unmanaged<NetworkReachabilityManager>.fromOpaque(info!).takeUnretainedValue()
                // 调用方法
                reachability.notifyListener(flags)
            },
            &context
        )
        /// 注册队列
        let queueEnabled = SCNetworkReachabilitySetDispatchQueue(reachability, listenerQueue)
        /// 通知网络状态发送改变
        listenerQueue.async {
            self.previousFlags = SCNetworkReachabilityFlags()
            self.notifyListener(self.flags ?? SCNetworkReachabilityFlags())
        }

        return callbackEnabled && queueEnabled
    }
    /// 停止监听
    /// Stops listening for changes in network reachability status.
    public func stopListening() {
        /// 取消回调
        SCNetworkReachabilitySetCallback(reachability, nil, nil)
        /// 取消队列
        SCNetworkReachabilitySetDispatchQueue(reachability, nil)
    }
    
    // MARK: - Internal - Listener Notification
    /// 回调中调用的函数
    func notifyListener(_ flags: SCNetworkReachabilityFlags) {
        /// 如果网络状态没有发生改变, 则不通知
        guard previousFlags != flags else { return }
        previousFlags = flags
        /// 通知接受者
        listener?(networkReachabilityStatusForFlags(flags))
    }

    // MARK: - Internal - Network Reachability Status
    /// 根据系统类型, 构建网络状态
    func networkReachabilityStatusForFlags(_ flags: SCNetworkReachabilityFlags) -> NetworkReachabilityStatus {
        /// 首先判断是否可达
        guard isNetworkReachable(with: flags) else { return .notReachable }
        /// 初始值设置为通过wifi 可达
        var networkStatus: NetworkReachabilityStatus = .reachable(.ethernetOrWiFi)

    #if os(iOS)
        /// 如果 flag 中包含了移动网络, 则为移动网络可达
        if flags.contains(.isWWAN) { networkStatus = .reachable(.wwan) }
    #endif

        return networkStatus
    }

    func isNetworkReachable(with flags: SCNetworkReachabilityFlags) -> Bool {
        /// 是否可达
        let isReachable = flags.contains(.reachable)
        /// 是否需要连接
        let needsConnection = flags.contains(.connectionRequired)
        /// 是否是自动连接
        let canConnectAutomatically = flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic)
        /// 如果是自动连接, 那么是否可以不需要用户确认即可连接
        let canConnectWithoutUserInteraction = canConnectAutomatically && !flags.contains(.interventionRequired)
        /// 可达的满足的要求: 可达且不需要连接, 或者需要连接, 但是可以自动连接, 而且自动连接不需要用户确认
        return isReachable && (!needsConnection || canConnectWithoutUserInteraction)
    }
}

// MARK: -
/// 相等协议的实现, 简单来说, 相等的条件是可达性一致, 且连接方式也是一致的
extension NetworkReachabilityManager.NetworkReachabilityStatus: Equatable {}

/// Returns whether the two network reachability status values are equal.
///
/// - parameter lhs: The left-hand side value to compare.
/// - parameter rhs: The right-hand side value to compare.
///
/// - returns: `true` if the two values are equal, `false` otherwise.
public func ==(
    lhs: NetworkReachabilityManager.NetworkReachabilityStatus,
    rhs: NetworkReachabilityManager.NetworkReachabilityStatus)
    -> Bool
{
    switch (lhs, rhs) {
    case (.unknown, .unknown):
        return true
    case (.notReachable, .notReachable):
        return true
    case let (.reachable(lhsConnectionType), .reachable(rhsConnectionType)):
        return lhsConnectionType == rhsConnectionType
    default:
        return false
    }
}

#endif
