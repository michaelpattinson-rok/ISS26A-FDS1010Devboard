import SwiftUI

/// Small flat diagrams stay in the normal view; detailed board renders live in help.
struct SetupDiagram: View {
    let topic: SetupHelpTopic
    var gain = "LOW"

    var body: some View {
        Group {
            switch topic {
            case .wiring:
                VStack(spacing: 8) {
                    HStack { Text("J2"); Spacer(); Text("Pico pin") }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    wire("1 GND", "33 AGND", color: .secondary)
                    wire("2 3V3", "36 3V3", color: .red)
                    wire("3 ADC", "31 GP26", color: .blue)
                }
            case .diagnostics, .stageWiring:
                VStack(spacing: 12) {
                    Text("J3 · left to right").font(.caption.weight(.semibold))
                    HStack(spacing: 5) {
                        ForEach(Array(["GND", "3V3", "VMID", "CSA", "GAIN", "SHP"].enumerated()), id: \.offset) { index, label in
                            VStack(spacing: 5) {
                                Circle().strokeBorder(index == 0 ? Color.accentColor : .secondary, lineWidth: 1.5).frame(width: 9, height: 9)
                                Text("\(index + 1)").font(.caption.monospacedDigit())
                                Text(label).font(.system(size: 9, weight: .medium))
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    Text("Black probe → GND").font(.caption).foregroundStyle(.secondary)
                }
            case .gain:
                VStack(spacing: 9) {
                    Text(gain == "HIGH" ? "HIGH: fit the J4 shunt" : "LOW: leave J4 open")
                        .font(.caption.weight(.semibold))
                    ZStack {
                        if gain == "HIGH" {
                            RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.2))
                                .frame(width: 70, height: 26)
                            RoundedRectangle(cornerRadius: 4).strokeBorder(.primary, lineWidth: 1).frame(width: 70, height: 26)
                        }
                        HStack(spacing: 35) {
                            Circle().fill(.primary).frame(width: 8, height: 8)
                            Circle().fill(.primary).frame(width: 8, height: 8)
                        }
                    }.frame(height: 28)
                    Text("Set by hand with USB off").font(.caption).foregroundStyle(.secondary)
                }
            case .detector, .baseline:
                VStack(spacing: 8) {
                    HStack { Text("J1"); Spacer(); Text("FDS1010") }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    wire("1 VMID", "Anode", color: .red)
                    wire("2 SUM", "Cathode", color: .secondary)
                    Label("Keep sensor dark", systemImage: "moon.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleDescription)
    }

    private func wire(_ left: String, _ right: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(left).frame(width: 52, alignment: .leading)
            HStack(spacing: 0) {
                Circle().fill(color).frame(width: 5, height: 5)
                Rectangle().fill(color).frame(height: 1.5)
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(right).frame(width: 58, alignment: .trailing)
        }.font(.caption.monospacedDigit())
    }

    private var accessibleDescription: String {
        switch topic {
        case .wiring: "J2 ground to Pico physical pin 33, 3.3 volts to pin 36, ADC to pin 31."
        case .diagnostics, .stageWiring: "J3 left to right: 1 ground, 2 supply, 3 midpoint, 4 CSA, 5 gain, 6 shaped output. Black probe on ground."
        case .gain: gain == "HIGH" ? "High gain: fit a shunt over both J4 pins with USB removed." : "Low gain: leave both J4 pins open. Remove USB before changes."
        case .detector, .baseline: "J1 pin 1 midpoint to detector anode, pin 2 SUM to cathode. Neither lead is ground. Keep detector dark."
        }
    }
}

struct SetupHintCard: View {
    let topic: SetupHelpTopic
    var gain = "LOW"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupDiagram(topic: topic, gain: gain)
            Divider()
            SetupHelpButton(topic: topic).font(.callout)
        }
        .padding(14)
        .frame(width: 200)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Diagrams sit on the right at normal widths and below instructions when narrow.
struct SetupHelpLayout<Content: View>: View {
    let topic: SetupHelpTopic
    var gain = "LOW"
    @ViewBuilder let content: () -> Content

    var body: some View {
        SetupInstructionLayout {
            content().frame(maxWidth: .infinity, alignment: .leading)
            SetupHintCard(topic: topic, gain: gain)
        }
    }
}

/// Measure text at its actual column width, rather than its unwrapped ideal width.
/// Scroll views get a complete intrinsic height in either arrangement.
private struct SetupInstructionLayout: Layout {
    private let diagramWidth: CGFloat = 200
    private let spacing: CGFloat = 20
    private let minimumTextWidth: CGFloat = 330

    private func measures(_ proposal: ProposedViewSize, subviews: Subviews) -> (CGFloat, Bool, CGSize, CGSize) {
        let idealWidth = minimumTextWidth + spacing + diagramWidth
        let proposedWidth = proposal.width ?? idealWidth
        let width = max(0, proposedWidth.isFinite ? proposedWidth : idealWidth)
        let horizontal = width >= minimumTextWidth + spacing + diagramWidth
        let textWidth = horizontal ? width - spacing - diagramWidth : width
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
        let diagram = subviews[1].sizeThatFits(ProposedViewSize(width: diagramWidth, height: nil))
        return (width, horizontal, text, diagram)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (width, horizontal, text, diagram) = measures(proposal, subviews: subviews)
        return CGSize(width: width, height: horizontal ? max(text.height, diagram.height) : text.height + spacing + diagram.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, horizontal, text, _) = measures(ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        let textWidth = horizontal ? bounds.width - spacing - diagramWidth : bounds.width
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: textWidth, height: text.height))
        let diagramOrigin = horizontal
            ? CGPoint(x: bounds.maxX - diagramWidth, y: bounds.minY)
            : CGPoint(x: bounds.minX, y: bounds.minY + text.height + spacing)
        subviews[1].place(at: diagramOrigin, anchor: .topLeading, proposal: ProposedViewSize(width: diagramWidth, height: nil))
    }
}
