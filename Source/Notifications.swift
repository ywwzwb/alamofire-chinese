//
//  Notifications.swift
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
// 对 notifycation.name 的扩展 用于发送与接收通知
extension Notification.Name {
    // 使用了一个内部类型, 用于指示通知名, 在这里作用类似于一个命名空间
    //使用方法为 NotificationCenter.default.post(name: NSNotification.Name.Task.DidCancel, object: nil)
    /// Used as a namespace for all `URLSessionTask` related notifications.
    public struct Task {
        /// 在 sessionTask 继续运行的时候会发送通知, 通知的 object 中含有此 task
        /// Posted when a `URLSessionTask` is resumed. The notification `object` contains the resumed `URLSessionTask`.
        public static let DidResume = Notification.Name(rawValue: "org.alamofire.notification.name.task.didResume")
        /// 在 sessionTask 停止的时候会发送通知, 通知的 object 中含有此 task
        /// Posted when a `URLSessionTask` is suspended. The notification `object` contains the suspended `URLSessionTask`.
        public static let DidSuspend = Notification.Name(rawValue: "org.alamofire.notification.name.task.didSuspend")
        /// 在 sessionTask 取消的时候会发送通知, 通知的 object 中含有此 task
        /// Posted when a `URLSessionTask` is cancelled. The notification `object` contains the cancelled `URLSessionTask`.
        public static let DidCancel = Notification.Name(rawValue: "org.alamofire.notification.name.task.didCancel")
        /// /// 在 sessionTask 结束的时候会发送通知, 通知的 object 中含有此 task
        /// Posted when a `URLSessionTask` is completed. The notification `object` contains the completed `URLSessionTask`.
        public static let DidComplete = Notification.Name(rawValue: "org.alamofire.notification.name.task.didComplete")
    }
}

// MARK: -

extension Notification {
    /// 这里也是起到一个命名空间的作用, 用于标记指定键值
    /// Used as a namespace for all `Notification` user info dictionary keys.
    public struct Key {
        /// 用于标记 userinfo 中 sessiontask 的键值
        /// User info dictionary key representing the `URLSessionTask` associated with the notification.
        public static let Task = "org.alamofire.notification.key.task"
    }
}
