import Foundation

/// 全局发布/调试日志工具：
/// 借助 `@autoclosure` 特性，仅在 DEBUG 模式下对入参表达式求值并输出。
/// 在 Release 构建中，编译器将整条日志及其内部的高开销字符串格式化完全消除，达到零 CPU 与零 I/O 开销。
@inline(__always)
func AppLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
