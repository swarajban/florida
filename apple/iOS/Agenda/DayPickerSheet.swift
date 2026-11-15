import SwiftUI

/// A month grid to jump to any day, opened from the Agenda tab's day heading. Tapping a day
/// selects it and closes the sheet; the month arrows only browse.
struct DayPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Binding private var isPresented: Bool
    @State private var day: Date

    init(selectedDay: Date, isPresented: Binding<Bool>) {
        _day = State(initialValue: selectedDay)
        _isPresented = isPresented
    }

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .environment(\.calendar, model.calendar)
                .padding(.horizontal)
                .onChange(of: day) { _, newValue in
                    isPresented = false
                    model.select(day: newValue)
                }
                .navigationTitle("Go to Day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") {
                            isPresented = false
                            model.selectToday()
                        }
                        .disabled(model.selectedDay == model.today)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isPresented = false
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FloridaStyle.paper)
    }
}
