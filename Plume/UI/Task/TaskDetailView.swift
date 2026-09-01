import SwiftUI
import SwiftData

struct TaskDetailView: View {
    @Bindable var task: WorkTask

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(task: task)
            Divider()
            TabContentView(task: task)
        }
        .navigationTitle(task.title)
    }
}
