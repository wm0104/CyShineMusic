import 'package:flutter/material.dart';

/// A labelled slider with fine-step buttons.
///
/// There is deliberately no numeric field: the value is read from whatever the
/// setting drives (the lyric preview, the crossfade length), so no digits pop
/// up before, during or after a drag.
class SettingsNumberControl extends StatefulWidget {
  const SettingsNumberControl({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.continuousLabel,
    this.commitOnRelease = true,
  });

  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  // A continuous slider has no ticks: the thumb stays where the finger is.
  final String Function(double)? continuousLabel;
  // Continuous controls either preview locally and commit on release, or land
  // every move. The lyric sheet needs the latter so it tracks the finger.
  final bool commitOnRelease;

  @override
  State<SettingsNumberControl> createState() => SettingsNumberControlState();
}

class SettingsNumberControlState extends State<SettingsNumberControl> {
  double? _dragValue;
  int? _lastCommitted;
  bool get _continuous => widget.continuousLabel != null;
  bool get _live => _continuous && !widget.commitOnRelease;

  double _snap(double value) => _continuous
      ? value.clamp(widget.min, widget.max)
      : ((value.clamp(widget.min, widget.max) / widget.step).round() *
                widget.step)
            .clamp(widget.min, widget.max);

  String _format(double value) =>
      widget.continuousLabel?.call(value) ?? value.round().toString();

  /// Used by the lyric sheet's reset button.
  void setValue(double value) => widget.onChanged(_snap(value));

  // A continuous drag moves the thumb 1:1 with the finger and lands the
  // rounded position, so the preview follows the finger instead of stepping.
  void _onSlide(double value) {
    if (!_continuous) {
      setValue(value);
      return;
    }
    final next = value.clamp(widget.min, widget.max);
    setState(() => _dragValue = next);
    if (!_live) return;
    final rounded = next.round();
    if (rounded == _lastCommitted) return;
    _lastCommitted = rounded;
    widget.onChanged(rounded.toDouble());
  }

  void _onSlideEnd(double value) {
    if (!_continuous) return;
    setState(() => _dragValue = null);
    _lastCommitted = null;
    if (!_live) widget.onChanged(value.clamp(widget.min, widget.max));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    return Column(
      children: [
        Row(
          children: [
            Icon(widget.icon, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                widget.label,
                style: theme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton.filledTonal(
              tooltip: '减小${widget.label}',
              onPressed: widget.value <= widget.min
                  ? null
                  : () => setValue(widget.value - widget.step),
              style: IconButton.styleFrom(
                minimumSize: const Size(40, 40),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.remove_rounded, size: 20),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 18,
                  ),
                  activeTickMarkColor: Colors.transparent,
                  inactiveTickMarkColor: Colors.transparent,
                  // Live sliders hide the bubble as well: nothing numeric pops
                  // up while adjusting, the preview itself is the feedback.
                  showValueIndicator: _continuous && widget.commitOnRelease
                      ? ShowValueIndicator.onDrag
                      : ShowValueIndicator.never,
                  valueIndicatorShape:
                      const RoundedRectSliderValueIndicatorShape(),
                ),
                child: Slider(
                  value: _dragValue ?? widget.value,
                  label: widget.continuousLabel?.call(
                    _dragValue ?? widget.value,
                  ),
                  min: widget.min,
                  max: widget.max,
                  divisions: _continuous
                      ? null
                      : ((widget.max - widget.min) / widget.step).round(),
                  semanticFormatterCallback: _format,
                  onChanged: _onSlide,
                  onChangeEnd: _continuous ? _onSlideEnd : null,
                ),
              ),
            ),
            IconButton.filledTonal(
              tooltip: '增大${widget.label}',
              onPressed: widget.value >= widget.max
                  ? null
                  : () => setValue(widget.value + widget.step),
              style: IconButton.styleFrom(
                minimumSize: const Size(40, 40),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.add_rounded, size: 20),
            ),
          ],
        ),
      ],
    );
  }
}
