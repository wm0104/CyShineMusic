// 仅导出桌面 Widget；系统媒体岛由 audio_service / NowPlaying 驱动。
import SwiftUI
import WidgetKit

@main
struct CyShineMusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        CyShineHomeWidget()
    }
}
