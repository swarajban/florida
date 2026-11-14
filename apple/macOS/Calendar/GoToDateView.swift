import SwiftUI

/// The `g d` sheet: a graphical date picker that jumps the view.
struct GoToDateView: View {
    @Environment(AppModel.self) private var model
    @State private var date = Date()
    @State private var isDateOpen = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Go to date")
                .font(.headline)
            MacDateField("Date", date: $date, isPresented: $isDateOpen, identifier: "go-to-date")
            HStack {
                Button("Cancel") {
                    model.isGoToDateOpen = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Go") {
                    model.goTo(day: date)
                    model.isGoToDateOpen = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            date = model.selectedDay
            isDateOpen = true
        }
    }
}
