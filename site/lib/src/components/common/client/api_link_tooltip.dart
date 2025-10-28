// Copyright 2025 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:http/http.dart' as http;
import 'package:jaspr/jaspr.dart';
import 'package:meta/meta.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import '../../../util.dart';
import '../../util/global_event_listener.dart';

@client
class ApiLinkTooltip extends StatefulComponent {
  const ApiLinkTooltip({required this.url, required this.text, super.key});

  final String url;
  final String text;

  @override
  State<ApiLinkTooltip> createState() => _InteractiveApiLinkState();
}

class _InteractiveApiLinkState extends State<ApiLinkTooltip> {
  final wrapperKey = GlobalNodeKey<web.HTMLElement>();
  final tooltipKey = GlobalNodeKey<web.HTMLElement>();
  Component? tooltipContent;

  bool isTouchscreen = false;
  bool isVisible = false;
  double tooltipOffset = 0.0;

  @override
  void initState() {
    super.initState();

    if (kIsWeb) {
      setupTooltip();
    }
  }

  @awaitNotRequired
  Future<void> setupTooltip() async {
    final (extractedHeader, extractedDescription) = await scrapeApiDocs(
      component.url,
    );

    if (!mounted) return;
    setState(() {
      tooltipContent = fragment([
        if (extractedHeader != null)
          span(classes: 'tooltip-header', [raw(extractedHeader)]),
        if (extractedDescription != null)
          span(classes: 'tooltip-content', [raw(extractedDescription)]),
      ]);

      isTouchscreen = web.window.matchMedia('(pointer: coarse)').matches;
    });

    context.binding.addPostFrameCallback(ensureVisible);

    // Reposition tooltips on window resize.
    web.EventStreamProviders.resizeEvent.forTarget(web.window).listen((_) {
      ensureVisible();
    });
  }

  /// Adjust the tooltip position to ensure it is fully inside the
  /// ancestor .content element.
  void ensureVisible() {
    final tooltip = tooltipKey.currentNode;
    if (tooltip == null) return;
    final containerRect = tooltip.closest('.content')!.getBoundingClientRect();
    final tooltipRect = tooltip.getBoundingClientRect();

    final tooltipLeft = tooltipRect.left - tooltipOffset;
    final tooltipRight = tooltipRect.right - tooltipOffset;

    if (tooltipLeft < containerRect.left) {
      setState(() => tooltipOffset = containerRect.left - tooltipLeft);
    } else if (tooltipRight > containerRect.right) {
      setState(() => tooltipOffset = containerRect.right - tooltipRight);
    } else {
      setState(() => tooltipOffset = 0.0);
    }
  }

  @override
  Component build(BuildContext context) {
    Component? tooltip;

    if (tooltipContent != null) {
      tooltip = span(
        key: tooltipKey,
        classes: ['tooltip', if (isVisible) 'visible'].toClasses,
        styles: Styles(
          raw: {
            'left': tooltipOffset == 0
                ? '50%'
                : 'calc(50% + ${tooltipOffset}px)',
          },
        ),
        [tooltipContent!],
      );

      if (isTouchscreen) {
        tooltip = GlobalEventListener(
          // Close tooltip when clicking outside of this wrapper.
          onClick: (e) {
            if (wrapperKey.currentNode?.contains(e.target as web.Node?) ==
                true) {
              return;
            }
            setState(() => isVisible = false);
          },
          // On touchscreen devices, close tooltips when scrolling.
          onScroll: (_) {
            setState(() => isVisible = false);
          },
          tooltip,
        );
      }
    }

    return span(key: wrapperKey, classes: 'tooltip-wrapper', [
      a(
        href: component.url,
        classes: 'tooltip-target',
        events: {
          if (isTouchscreen)
            'click': (event) {
              setState(() => isVisible = !isVisible);
              event.preventDefault();
            },
        },
        [
          code([text(component.text)]),
        ],
      ),
      ?tooltip,
    ]);
  }
}

const contentId = 'dartdoc-main-content';
// This seems to be a good limit to avoid overly small or large tooltips.
const maxDescriptionLength = 400;
const minTrailingParagraphLength = 20;

@awaitNotRequired
Future<(String?, String?)> scrapeApiDocs(String url) async {
  try {
    final response = await http.get(Uri.parse(url));
    var content = response.body;

    content = content.substring(
      content.indexOf(RegExp('<div\\s+id="$contentId"')),
    );

    final element =
        web.document.createElement('template') as web.HTMLTemplateElement;
    element.innerHTML = content.toJS;
    final fragment = element.content;

    final header = fragment.querySelector('#$contentId div h1');
    final description = fragment.querySelector(
      '#$contentId section.desc',
    );

    // Remove any feature badge from the header (like "abstract" or "final").
    final featureBadges = header?.querySelectorAll('.feature');
    if (featureBadges != null) {
      for (var i = 0; i < featureBadges.length; i++) {
        final featureBadge = featureBadges.item(i);
        featureBadge?.parentNode?.removeChild(featureBadge);
      }
    }
    // Limit description to not exceed <maxDescriptionLength> characters.
    // This only removes full paragraphs and does not truncate individual ones.
    var charCount = 0;
    if (description != null) {
      final children = description.childNodes;
      var removeFrom = -1;
      for (var i = 0; i < children.length; i++) {
        final child = children.item(i)!;

        if (child.instanceOfString('HTMLHeadingElement')) {
          // Stop at any headings.
          removeFrom = i;
          break;
        }

        if (child.textContent?.startsWith('See also') == true) {
          // Stop at "See also" sections.
          removeFrom = i;
          break;
        }

        if (!child.instanceOfString('HTMLParagraphElement')) {
          // Skip non-paragraph elements (such as video embeds, code snippets).
          description.removeChild(child);
          i--;
          continue;
        }

        charCount += child.textContent?.length ?? 0;

        if (charCount > maxDescriptionLength) {
          removeFrom = i;
          break;
        }
      }

      // Remove any extra paragraphs beyond the max characters.
      if (removeFrom > 0) {
        while (children.length > removeFrom) {
          description.removeChild(children.item(children.length - 1)!);
        }

        // If the last paragraph is very short, remove it as well.
        // This avoids having trailing "See also" or similar.
        while (children.length > 1 &&
            (children.item(children.length - 1)!.textContent?.length ?? 0) <
                minTrailingParagraphLength) {
          description.removeChild(children.item(children.length - 1)!);
        }
      }

      // Append a "Read more" link to the full docs.
      description.appendChild(
        web.document.createElement('a')
          ..setAttribute('href', url)
          ..textContent = 'Read more.',
      );
    }

    return (
      (header?.innerHTML as JSString?)?.toDart,
      (description?.innerHTML as JSString?)?.toDart,
    );
  } catch (e) {
    print('Error fetching API docs for $url: $e');
    return (null, null);
  }
}
