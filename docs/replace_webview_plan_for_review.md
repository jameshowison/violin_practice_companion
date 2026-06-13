# Technical Blueprint: Headless OSMD + Responsive Flutter Native Semantics

This came from a Google AI mode session; it is to be viewed and thought about in relation to our specific app. Do not implement, just use for critique. Pros and Cons. Does this help with cross platform debugging?

### Context & Goal
We are replacing our resource-heavy embedded `WebView` (which displays OpenSheetMusicDisplay/OSMD) with a native, highly responsive Flutter rendering layer. 
* **The Problem:** WebViews are heavy, inefficient, and create massive sandboxing issues for tracking user layout element metrics natively.
* **The Solution:** Use OSMD headlessly (via Node.js) to handle the engraving logic, generate flat SVG vectors, and output a normalized percentage-based JSON map of elements. Flutter will render the SVG visually while using native layout boundaries to map responsive touch zones flawlessly across any device size or orientation.

---

### Step 1: Headless OSMD Engraving & Coordinate Normalization Pipeline
The engraving pipeline runs inside a background worker or server environment. It spins up OSMD using a virtual DOM (`jsdom`), measures the graphical musical sheet layout, and normalizes all absolute pixels into scale-independent ratios.

1. **Calculate Global Dimensions:** Capture the base canvas bounding width ($W_{base}$) and height ($H_{base}$) utilized by OSMD.
2. **Compute Percentage Ratios:** For every single note, ledger line, or measure element, convert its raw bounding box layout coordinates into normalized floating-point percentages between `0.0` and `1.0`:
   $$\text{Ratio} = \frac{\text{Absolute Element Coordinate}}{\text{Base Canvas Dimension}}$$
3. **Compile Output Payload:** Package the layout coordinates and SVG code into a structured JSON payload:

```json
{
  "canvas_base_width": 1200.0,
  "canvas_base_height": 600.0,
  "svg_string": "<svg ...>...</svg>",
  "bounding_boxes": [
    {
      "id": "note_001",
      "label": "Quarter Note C4",
      "x_ratio": 0.3245,
      "y_ratio": 0.1850,
      "w_ratio": 0.0210,
      "h_ratio": 0.0340
    },
    {
      "id": "note_002",
      "label": "Half Note E4",
      "x_ratio": 0.4810,
      "y_ratio": 0.1520,
      "w_ratio": 0.0210,
      "h_ratio": 0.0340
    }
  ]
}
```

---

### Step 2: Implementation of the Responsive Flutter Stack Widget
Implement a Flutter view architecture that acts as a real-time scaling computer. By intercepting constraints via `LayoutBuilder`, the widget continuously re-multiplies ratios against physical screen configurations during system events (such as app resizing, split-screen viewing, or phone rotation).

1. **Add Dependency:** Install the high-performance `flutter_svg` package.
2. **Build the Responsive Matrix:** Use a `Stack` to anchor the visuals and interaction target zones. Use `BoxFit.fill` on the SVG to ensure vector paths match the calculated percentage boundaries perfectly.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class ResponsiveMusicalStaff extends StatelessWidget {
  final Map<String, dynamic> scoreData;
  final Function(String noteId) onNoteTapped;

  const ResponsiveMusicalStaff({
    super.key,
    required this.scoreData,
    required this.onNoteTapped,
  });

  @override
  Widget build(BuildContext context) {
    final List<dynamic> boxes = scoreData['bounding_boxes'];
    final String svgRaw = scoreData['svg_string'];

    return LayoutBuilder(
      builder: (context, constraints) {
        // 1. Intercept the real-time physical screen boundaries
        final double currentWidth = constraints.maxWidth;
        final double currentHeight = constraints.maxHeight;

        return Stack(
          children: [
            // LAYER 1: Visual Presentation
            // BoxFit.fill guarantees vector boundaries mirror the percentage calculations
            SvgPicture.string(
              svgRaw,
              width: currentWidth,
              height: currentHeight,
              fit: BoxFit.fill,
            ),

            // LAYER 2: Scaled Native Touch/Accessibility Elements
            ...boxes.map((box) {
              // 2. Re-calculate pixel dimensions in real time (Triggers on phone rotation)
              final double liveX = box['x_ratio'] * currentWidth;
              final double liveY = box['y_ratio'] * currentHeight;
              final double liveW = box['w_ratio'] * currentWidth;
              final double liveH = box['h_ratio'] * currentHeight;

              return Positioned(
                left: liveX,
                top: liveY,
                child: Semantics(
                  label: box['label'],
                  identifier: box['id'],
                  button: true,
                  child: GestureDetector(
                    onTap: () => onNoteTapped(box['id']),
                    child: Container(
                      width: liveW,
                      height: liveH,
                      color: Colors.transparent, // Ensures hit testing handles the area seamlessly
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
```

---

### Step 3: Verification Checkpoints
When generating this feature, confirm accuracy against the following parameters:
* **Rotation Resilience:** Change target configurations to Landscape and verify that hitboxes follow visual stretching perfectly without layout drift.
* **Semantic Verification:** Inspect the widget layout tree to ensure `Semantics` boundaries wrap cleanly around the exact bounding parameters of individual notes.
