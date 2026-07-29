import Foundation

public enum WisprError: Error, Equatable {
    case modelNotLoaded
    case recordingFailed
    case hotkeyTapFailed
    case audioFileUnreadable(String)
    case audioFileTooLong
}
