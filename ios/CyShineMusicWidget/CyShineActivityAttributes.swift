// 旧版自定义播放活动的数据结构，由主 App 在启动时识别并清理旧活动。

import ActivityKit
import Foundation

/// 保留旧版类型名及 Codable 字段，供 CyShineLiveActivityBridge 识别存量活动。
struct CyShineActivityAttributes: ActivityAttributes {

    /// 随每次更新变化的部分。
    struct ContentState: Codable, Hashable {
        /// 歌名
        var title: String
        /// 歌手
        var artist: String
        /// 当前播放位置（毫秒）
        var positionMs: Int
        /// 总时长（毫秒）；0 表示未知（直播/未解析出时长）
        var durationMs: Int
        /// 是否正在播放
        var playing: Bool
        /// 这份状态生成的时刻（自 1970 起的秒）。
        var updatedAt: TimeInterval
        /// 封面在 App Group 容器里的相对路径；拿不到共享容器时为 nil。
        var artworkPath: String?
    }

    /// 当前活动的曲目标识，换歌时重新发起活动。
    var trackId: String
}
