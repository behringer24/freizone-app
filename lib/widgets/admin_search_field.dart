import 'package:flutter/material.dart';

/// The Server Admin user list's search box (APP-10).
///
/// Its own widget for one reason: the vertical alignment of a *dense* field
/// with icons is easy to get wrong and impossible to see in a unit test unless
/// the field can be pumped on its own. See admin_search_field_test.dart, which
/// asserts the text and the icons share a centre line.
class AdminSearchField extends StatelessWidget {
  const AdminSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClear,
    this.width = 180,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final double width;

  @override
  Widget build(BuildContext context) {
    final hasQuery = controller.text.isNotEmpty;
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        // Filtering happens on every keystroke over a list already in memory,
        // so there is nothing to debounce.
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        // Without this the text sits above the icons rather than beside them.
        // A dense field with no label anchors its content to the top of the
        // content box, and the icons below make that box taller than the text
        // needs -- so the text ends up high and the field looks misaligned.
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search id',
          // The other half of the same problem: an icon box defaults to the
          // 48px minimum touch target, which stretches a dense field it has no
          // business stretching. These are sized for the icons they hold; the
          // clear button stays comfortably tappable at 32.
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Icon(Icons.search, size: 20),
          ),
          suffixIcon: !hasQuery
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Clear search',
                  // `constraints` alone is not enough: an IconButton also
                  // carries a 48x48 minimum in its ButtonStyle, which is what
                  // made this field grow from 40 to 48 the moment a query
                  // appeared -- so the text visibly moved as soon as you typed.
                  // Below the 48px guideline deliberately, for a compact
                  // control in a header row whose neighbours are the same size;
                  // 36 is still a comfortable target.
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(36, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onClear,
                ),
        ),
      ),
    );
  }
}
