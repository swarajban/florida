import AppKit
import FloridaKit

enum MacInteraction {
    case browsing
    case jumping(JumpLabels<ItemID>)
    case eventPopover(String)
    case dragging(GridDrag)
    case palette
    case help
    case availability(AvailabilityShareState, zoneOpen: Bool)
    case sheet(Sheet)

    enum Sheet {
        case task(TaskItem)
        case recurringTaskDelete(TaskItem)
        case eventEditor(EventEditorRequest)
        case eventDelete(CalendarEvent)
        case eventMove(EventMoveRequest)
        case goToDate
        case newCategory
        case doneForNow(DoneForNowRequest)
        case projects(editor: Project?)
        case brief
        case explanation(PlacementExplanation)
    }

    enum Kind: String {
        case browsing, jumping, eventPopover, dragging, palette, help, availability, sheet
    }

    var kind: Kind {
        switch self {
        case .browsing: .browsing
        case .jumping: .jumping
        case .eventPopover: .eventPopover
        case .dragging: .dragging
        case .palette: .palette
        case .help: .help
        case .availability: .availability
        case .sheet: .sheet
        }
    }
}

extension AppModel {
    var isPaletteOpen: Bool {
        get {
            if case .palette = interaction { return true }
            return false
        }
        set {
            if newValue { transitionInteraction(to: .palette) }
            else if isPaletteOpen { transitionInteraction(to: .browsing) }
        }
    }

    var isHelpOpen: Bool {
        get {
            if case .help = interaction { return true }
            return false
        }
        set {
            if newValue { transitionInteraction(to: .help) }
            else if isHelpOpen { transitionInteraction(to: .browsing) }
        }
    }

    var jump: JumpLabels<ItemID>? {
        get {
            if case .jumping(let labels) = interaction { return labels }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .jumping(newValue)) }
            else if jump != nil { transitionInteraction(to: .browsing) }
        }
    }

    var eventDetailID: String? {
        get {
            if case .eventPopover(let id) = interaction { return id }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .eventPopover(newValue)) }
            else if eventDetailID != nil { transitionInteraction(to: .browsing) }
        }
    }

    var gridDrag: GridDrag? {
        get {
            if case .dragging(let drag) = interaction { return drag }
            return droppedGridDrag
        }
        set {
            if let newValue, !newValue.isDropped {
                droppedGridDrag = nil
                transitionInteraction(to: .dragging(newValue))
            } else {
                droppedGridDrag = newValue
                if case .dragging = interaction { transitionInteraction(to: .browsing) }
            }
        }
    }

    var canBeginGridDrag: Bool {
        switch interaction {
        case .browsing, .jumping, .eventPopover: true
        default: false
        }
    }

    var availabilityShare: AvailabilityShareState? {
        get {
            if case .availability(let share, _) = interaction { return share }
            return nil
        }
        set {
            if let newValue {
                transitionInteraction(to: .availability(newValue, zoneOpen: isAvailabilityZoneOpen))
            } else if availabilityShare != nil {
                transitionInteraction(to: .browsing)
            }
        }
    }

    var isAvailabilityZoneOpen: Bool {
        get {
            if case .availability(_, let open) = interaction { return open }
            return false
        }
        set {
            guard let share = availabilityShare else { return }
            transitionInteraction(to: .availability(share, zoneOpen: newValue))
        }
    }

    var isSheetOpen: Bool {
        if case .sheet = interaction { return true }
        return false
    }

    private var interactionSheet: MacInteraction.Sheet? {
        if case .sheet(let sheet) = interaction { return sheet }
        return nil
    }

    var editorTask: TaskItem? {
        get {
            if case .task(let task)? = interactionSheet { return task }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .sheet(.task(newValue))) }
            else if editorTask != nil { transitionInteraction(to: .browsing) }
        }
    }

    var recurringTaskToDelete: TaskItem? {
        get {
            if case .recurringTaskDelete(let task)? = interactionSheet { return task }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .sheet(.recurringTaskDelete(newValue))) }
            else if recurringTaskToDelete != nil { transitionInteraction(to: .browsing) }
        }
    }

    var eventEditor: EventEditorRequest? {
        get {
            if case .eventEditor(let request)? = interactionSheet { return request }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .sheet(.eventEditor(newValue))) }
            else if eventEditor != nil { transitionInteraction(to: .browsing) }
        }
    }

    var eventToDelete: CalendarEvent? {
        get {
            if case .eventDelete(let event)? = interactionSheet { return event }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .sheet(.eventDelete(newValue))) }
            else if eventToDelete != nil { transitionInteraction(to: .browsing) }
        }
    }

    var eventMove: EventMoveRequest? {
        get {
            if case .eventMove(let request)? = interactionSheet { return request }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .sheet(.eventMove(newValue))) }
            else if eventMove != nil { transitionInteraction(to: .browsing) }
        }
    }

    var isGoToDateOpen: Bool {
        get {
            if case .goToDate? = interactionSheet { return true }
            return false
        }
        set {
            if newValue { transitionInteraction(to: .sheet(.goToDate)) }
            else if isGoToDateOpen { transitionInteraction(to: .browsing) }
        }
    }

    var isNewCategoryOpen: Bool {
        get {
            if case .newCategory? = interactionSheet { return true }
            return false
        }
        set {
            if newValue { transitionInteraction(to: .sheet(.newCategory)) }
            else if isNewCategoryOpen { transitionInteraction(to: .browsing) }
        }
    }

    var doneForNow: DoneForNowRequest? {
        get {
            if case .doneForNow(let request)? = interactionSheet { return request }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .sheet(.doneForNow(newValue))) }
            else if doneForNow != nil { transitionInteraction(to: .browsing) }
        }
    }

    var isProjectsOpen: Bool {
        get {
            if case .projects? = interactionSheet { return true }
            return false
        }
        set {
            if newValue, !isProjectsOpen { transitionInteraction(to: .sheet(.projects(editor: nil))) }
            else if !newValue, isProjectsOpen { transitionInteraction(to: .browsing) }
        }
    }

    var projectEditor: Project? {
        get {
            if case .projects(let editor)? = interactionSheet { return editor }
            return nil
        }
        set {
            guard newValue != nil || isProjectsOpen else { return }
            transitionInteraction(to: .sheet(.projects(editor: newValue)))
        }
    }

    var isBriefOpen: Bool {
        get {
            if case .brief? = interactionSheet { return true }
            return false
        }
        set {
            if newValue { transitionInteraction(to: .sheet(.brief)) }
            else if isBriefOpen { transitionInteraction(to: .browsing) }
        }
    }

    var explanation: PlacementExplanation? {
        get {
            if case .explanation(let result)? = interactionSheet { return result }
            return nil
        }
        set {
            if let newValue { transitionInteraction(to: .sheet(.explanation(newValue))) }
            else if explanation != nil { transitionInteraction(to: .browsing) }
        }
    }

    func transitionInteraction(to next: MacInteraction) {
        let oldKind = interaction.kind
        if let share = availabilityShare, next.kind != .availability {
            availabilityEventsObserver?.cancel()
            availabilityEventsObserver = nil
            interaction = .browsing
            if let previous = share.previousViewMode {
                viewMode = previous
                rangeDidChange()
            }
        }
        if oldKind == .palette, next.kind != .palette { palette = PaletteState() }
        if oldKind == .jumping, next.kind != .jumping { jumpGridViewport = nil }
        if oldKind == .eventPopover {
            eventResourceKeys = nil
            eventDetailIndicatorDay = nil
        }
        if editorTask != nil {
            switch next {
            case .sheet(.task): break
            default:
                editorAIText = nil
                editorQuickAddDraft = nil
                editorQuickAddCategoryId = nil
            }
        }
        if oldKind != next.kind { resetKeySequence() }
        interaction = next
    }
}
