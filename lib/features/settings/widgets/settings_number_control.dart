import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  late final _controller = TextEditingController(
    text: _inputText(widget.value),
  );
  final _focus = FocusNode();

  double? _dragValue;
  int? _lastCommitted;
  bool get _continuous => widget.continuousLabel != null;
  bool get _live => _continuous && !widget.commitOnRelease;

  String _inputText(double value) => _continuous
      ? value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '')
      : value.round().toString();

  double _snap(double value) => _continuous
      ? value.clamp(widget.min, widget.max)
      : ((value.clamp(widget.min, widget.max) / widget.step).round() *
                widget.step)
            .clamp(widget.min, widget.max);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_handleFocus);
  }

  @override
  void didUpdateWidget(covariant SettingsNumberControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.value != oldWidget.value) {
      _controller.text = _inputText(widget.value);
    }
  }

  void _handleFocus() {
    if (!_focus.hasFocus) commitInput();
  }

  void commitInput() {
    final parsed = double.tryParse(_controller.text.replaceAll(',', '.'));
    final value = _snap(parsed ?? widget.value);
    _controller.text = _inputText(value);
    if (value != widget.value) widget.onChanged(value);
  }

  void setValue(double value) {
    final next = _snap(value);
    _controller.text = _inputText(next);
    _focus.unfocus();
    widget.onChanged(next);
  }

  void _onTextChanged(String value) {
    final parsed = double.tryParse(value.replaceAll(',', '.'));
    if (parsed != null) widget.onChanged(_snap(parsed));
  }

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
  void dispose() {
    _focus.removeListener(_handleFocus);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    );
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  const SizedBox(height: 4),
                  Text(
                    _continuous
                        ? '${widget.min.round()}–${widget.max.round()}'
                        : '${widget.min.round()}–${widget.max.round()} · 每次 ${widget.step.round()}',
                    style: theme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Visibility(
              visible: _dragValue == null,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              child: SizedBox(
                width: 102,
                child: Semantics(
                  label: widget.label,
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    selectAllOnFocus: true,
                    keyboardType: _continuous
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.number,
                    textInputAction: TextInputAction.done,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: theme.titleMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    inputFormatters: [
                      TextInputFormatter.withFunction(
                        (oldValue, newValue) =>
                            (_continuous
                                    ? RegExp(r'^\d{0,4}([.,]\d{0,3})?$')
                                    : RegExp(r'^\d{0,4}$'))
                                .hasMatch(newValue.text)
                            ? newValue
                            : oldValue,
                      ),
                    ],
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: scheme.surfaceContainerHighest,
                      isDense: true,
                      contentPadding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
                      border: border,
                      enabledBorder: border,
                      focusedBorder: border.copyWith(
                        borderSide: BorderSide(
                          color: scheme.primary,
                          width: 1.5,
                        ),
                      ),
                      suffixIcon: Icon(
                        Icons.edit_outlined,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      suffixIconConstraints: const BoxConstraints(minWidth: 28),
                    ),
                    onChanged: _onTextChanged,
                    onSubmitted: (_) {
                      commitInput();
                      _focus.unfocus();
                    },
                    onTapOutside: (_) => _focus.unfocus(),
                  ),
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
                  semanticFormatterCallback:
                      widget.continuousLabel ?? _inputText,
                  onChangeStart: _continuous ? (_) => _focus.unfocus() : null,
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
