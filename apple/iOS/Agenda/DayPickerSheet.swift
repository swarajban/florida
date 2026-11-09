import SwiftUI

/// A month grid to jump to any day, opened from the Agenda tab's day heading. Tapping a day
/// selects it and closes the sheet; the month arrows only browse.
struct DayPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date

    init(selectedDay: Date) {
        _day = State(initialValue: selectedDay)
    }

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .environment(\.calendar, model.calendar)
                .padding(.horizontal)
                .onChange(of: day) { _, newValue in
                    model.select(day: newValue)
                    dismiss()
                }
                .navigationTitle("Go to Day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") {
                            model.selectToday()
                            dismiss()
                        }
                        .disabled(model.selectedDay == model.today)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FloridaStyle.paper)
    }
}
