import Foundation
import SwiftUI
// ActivityKit 必须显式写。Swift 的 import 是模块级的，
// 靠 SharedStore.swift 顺带带进来也能编过 —— 但哪天把它移出 target 就炸了，别赌。
import ActivityKit

// MARK: - 灵动岛的数据契约
//
// 这个文件必须同时编进主 App 和 Widget Extension：
//   · 主 App 的 IslandBridge 要用它发起 Activity
//   · Widget Extension 的 StillLiveActivity 要用它画界面
// 上 Xcode 记得给两个 target 都勾上。

struct StillActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        var phase: Phase
        var roomName: String
    }

    enum Phase: String, Codable, Hashable {
        case inside      // 它钻进岛里了
        case walking     // 它正在挪窝
    }

    // 不变的部分
    var roomName: String
}
