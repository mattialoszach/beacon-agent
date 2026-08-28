import Foundation

struct DefaultModelRouter: ModelRouting {
    let localModel: any InstructorModel

    init(localModel: any InstructorModel = AccessibilityHeuristicProvider()) {
        self.localModel = localModel
    }

    func selectModel(for request: InstructorRequest) -> any InstructorModel {
        localModel
    }
}
