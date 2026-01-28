actor ResumeGate {
    private var hasResumed = false

    func shouldResume() -> Bool {
        if hasResumed {
            return false
        }
        hasResumed = true
        return true
    }
}
