import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:collection';

enum UIDesign {
  material,
  cupertino,
}

enum RonelAction { advance, replace, recede, closeModal, logout, goToTab }

enum RonelPresentation {
  push,
  cover,
  modal,
  sheet,
  bottomSheet,
}

// RonelManager for managing individual WebView instances
class RonelManager {
  InAppWebViewController? _controller;
  UIDesign? _uiDesign;
  Color? _appBarColor;
  BuildContext? _context;

  // Logout callback
  VoidCallback? _onLogout;

  // Tab switching callback
  Function(String)? _onGoToTab;

  // Completer for pull-to-refresh functionality
  Completer<void>? _refreshCompleter;

  // Pull-to-refresh configuration from HTML attribute
  final ValueNotifier<bool> _pullToRefreshNotifier =
      ValueNotifier<bool>(false); // Default to disabled

  // Setter for context
  set context(BuildContext? context) {
    _context = context;
  }

  // Setter for logout callback
  set onLogout(VoidCallback? callback) {
    _onLogout = callback;
  }

  // Setter for tab switching callback
  set onGoToTab(Function(String)? callback) {
    _onGoToTab = callback;
  }

  // Getter for pull-to-refresh status
  bool get isPullToRefreshEnabled => _pullToRefreshNotifier.value;

  // Getter for pull-to-refresh notifier
  ValueNotifier<bool> get pullToRefreshNotifier => _pullToRefreshNotifier;

  // Getter for InAppWebViewController
  InAppWebViewController get controller {
    if (_controller == null) {
      throw StateError(
          'InAppWebViewController not initialized. Call initialize() first.');
    }
    return _controller!;
  }

  void initialize({
    required String baseUrl,
    required UIDesign uiDesign,
    Color? appBarColor,
  }) {
    _uiDesign = uiDesign;
    _appBarColor = appBarColor;

    // InAppWebViewController is created and managed within the WebView widget itself
    // for better state management with IndexedStack and other Flutter widgets.
    // The manager will primarily hold a reference and handle high-level logic.
    // The actual InAppWebView widget instantiation will happen in the UI layer.
  }

  // This method is now primarily for initial load or programmatic reloads of the main WebView.
  void loadUrl(String url) {
    if (_controller != null) {
      _controller!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  void _injectLinkInterceptor(InAppWebViewController controller) {
    controller.evaluateJavascript(source: '''
      (function() {
        // Prevent multiple injections
        if (window.flutterLinkHandlerInjected) {
          return;
        }
        
        // Remove any existing event listeners to avoid duplicates
        if (window.flutterLinkHandler) {
          document.removeEventListener('click', window.flutterLinkHandler, true);
        }
        
        // Define the click handler
        window.flutterLinkHandler = function(event) {
          try {
            var target = event.target;
            
            // First check if the clicked element or any parent has data-ronel-action or data-action attribute
            var actionElement = null;
            var currentElement = target;
            var maxDepth = 10; // Prevent infinite loops
            var depth = 0;
            
            // Walk up the DOM tree to find an element with data-ronel-action or data-action
            while (currentElement && currentElement !== document && depth < maxDepth) {
              if (currentElement.getAttribute && (currentElement.getAttribute('data-ronel-action') || currentElement.getAttribute('data-action'))) {
                actionElement = currentElement;
                break;
              }
              currentElement = currentElement.parentElement;
              depth++;
            }
            
            // If we found an element with data-ronel-action, handle it
            if (actionElement) {
              event.preventDefault();
              event.stopPropagation();
              
              var linkData = {
                href: actionElement.href || actionElement.getAttribute('href') || '',
                text: (actionElement.textContent || actionElement.innerText || '').substring(0, 500), // Limit text length
                alt: actionElement.getAttribute('alt') || '',
                isModal: actionElement.getAttribute('data-ronel-modal') === 'true' || actionElement.getAttribute('data-presentation') === 'modal',
                title: actionElement.title || actionElement.getAttribute('title') || '',
                customAppBarTitle: actionElement.getAttribute('data-ronel-appbartitle') || '',
                action: actionElement.getAttribute('data-ronel-action') || actionElement.getAttribute('data-action') || 'advance',
                presentation: actionElement.getAttribute('data-ronel-presentation') || actionElement.getAttribute('data-presentation') || 'push'
              };
              
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('FlutterNavigation', linkData);
              }
              return;
            }
            
            // Fallback: check if it's an anchor tag without data-ronel-action or data-action but potentially with other data attributes
            var anchorElement = target;
            depth = 0;
            while (anchorElement && anchorElement.tagName !== 'A' && depth < maxDepth) {
              anchorElement = anchorElement.parentElement;
              depth++;
            }
            
            if (anchorElement && anchorElement.tagName === 'A' && !anchorElement.getAttribute('data-ronel-action') && !anchorElement.getAttribute('data-action')) {
              event.preventDefault();
              
              var linkData = {
                href: anchorElement.href,
                text: (anchorElement.textContent || anchorElement.innerText || '').substring(0, 500), // Limit text length
                alt: anchorElement.getAttribute('alt') || '',
                isModal: anchorElement.getAttribute('data-ronel-modal') === 'true' || anchorElement.getAttribute('data-presentation') === 'modal',
                title: anchorElement.title || '',
                customAppBarTitle: anchorElement.getAttribute('data-ronel-appbartitle') || '',
                action: anchorElement.getAttribute('data-ronel-action') || anchorElement.getAttribute('data-action') || 'advance',
                presentation: anchorElement.getAttribute('data-ronel-presentation') || anchorElement.getAttribute('data-presentation') || 'push'
              };
              
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('FlutterNavigation', linkData);
              }
            }
          } catch (error) {
            console.error('Error in flutterLinkHandler:', error);
          }
        };
        
        // Add the event listener
        document.addEventListener('click', window.flutterLinkHandler, true);
        
        // Mark as injected
        window.flutterLinkHandlerInjected = true;
        
      })();
    ''');
  }

  void _checkPullToRefreshAttribute(InAppWebViewController controller) {
    controller.evaluateJavascript(source: '''
      function checkPullRefresh() {
        var body = document.body;
        if (body) {
          var pullRefreshAttr = body.getAttribute('data-ronel-pull-refresh');
          if (pullRefreshAttr === 'true') {
            window.flutter_inappwebview.callHandler('RonelPullRefreshStatus', {
              pullToRefresh: 'true'
            });
          } else {
            window.flutter_inappwebview.callHandler('RonelPullRefreshStatus', { // Corrected channel name
              pullToRefresh: 'false'
            });
          }
        }
      }
      
      if (document.readyState === 'complete') {
        checkPullRefresh();
      } else {
        document.addEventListener('DOMContentLoaded', checkPullRefresh);
        window.addEventListener('load', checkPullRefresh);
      }
    ''');
  }

  void _handlePullRefreshMessage(dynamic message) {
    try {
      // message is already the parsed JavaScript object
      final String pullToRefreshStr = message['pullToRefresh'] ?? '';

      // Parse the attribute value - "true" enables, anything else disables
      final bool newValue = pullToRefreshStr.toLowerCase() == 'true';

      // Update the pull-to-refresh notifier
      _pullToRefreshNotifier.value = newValue;
    } catch (e) {
      debugPrint('Error parsing pull-to-refresh message: $e');
      // Default to disabled on parse error
      _pullToRefreshNotifier.value = false;
    }
  }

  void _handleLinkClick(dynamic linkData) {
    final context = _getNavigationContext();
    if (context == null) return;

    try {
      // linkData is already the parsed JavaScript object
      final String href = linkData['href'] ?? '';
      final String alt = linkData['alt'] ?? '';
      final bool isModal = linkData['isModal'] ?? false;
      final String title = linkData['title'] ?? '';
      final String customAppBarTitle = linkData['customAppBarTitle'] ?? '';
      final String actionStr = linkData['action'] ?? 'advance';
      final String presentationStr = linkData['presentation'] ?? 'push';

      debugPrint('Link clicked: href="$href", action="$actionStr", presentation="$presentationStr", isModal="$isModal"');

      // Parse action first
      final action = _parseAction(actionStr);

      // Handle actions that don't require URL navigation
      if (action == RonelAction.recede || action == RonelAction.closeModal) {
        Navigator.of(context).pop();
        return;
      }

      // Handle go_to_tab action
      if (action == RonelAction.goToTab) {
        final tabTitle = _extractTabTitleFromAction(actionStr);
        if (tabTitle != null) {
          debugPrint('Go to tab requested: $tabTitle');
          if (_onGoToTab != null) {
            _onGoToTab!(tabTitle);
          } else if (RonelAuth._globalGoToTabCallback != null) {
            debugPrint('Using global go to tab callback');
            RonelAuth._globalGoToTabCallback!(tabTitle);
          } else {
            debugPrint('No go to tab callback available');
          }
        }
        return;
      }

      if (href.isEmpty) return;

      // Parse presentation
      final presentation = isModal
          ? RonelPresentation.modal
          : _parsePresentation(presentationStr);

      debugPrint('Parsed presentation: $presentation, parsed action: $action');

      // Determine the display title: custom appbar title > title attribute > alt attribute > empty string
      final String displayTitle = customAppBarTitle.isNotEmpty
          ? customAppBarTitle
          : (title.isNotEmpty ? title : (alt.isNotEmpty ? alt : ''));

      navigate(
        context: context,
        url: href,
        title: displayTitle,
        action: action,
        presentation: presentation,
      );
    } catch (e) {
      debugPrint('Error parsing link data: $e');
    }
  }

  void _handleBridgeMessage(dynamic message) {
    final context = _getNavigationContext();
    if (context == null) return;

    try {
      // message is already the parsed JavaScript object
      final String actionStr = message['action'] ?? '';
      final bool isInModal = message['isInModal'] ?? false;

      if (actionStr == 'recede' || actionStr == 'close_modal') {
        Navigator.of(context).pop();
        return;
      }

      // Handle go_to_tab action
      final action = _parseAction(actionStr);
      if (action == RonelAction.goToTab) {
        final tabTitle = _extractTabTitleFromAction(actionStr);
        if (tabTitle != null) {
          debugPrint('Go to tab requested via bridge: $tabTitle');
          if (_onGoToTab != null) {
            _onGoToTab!(tabTitle);
          } else if (RonelAuth._globalGoToTabCallback != null) {
            debugPrint('Using global go to tab callback via bridge');
            RonelAuth._globalGoToTabCallback!(tabTitle);
          } else {
            debugPrint('No go to tab callback available via bridge');
          }
        }
        return;
      }

      // Handle navigation within modals
      if (isInModal && actionStr == 'advance') {
        final String href = message['href'] ?? '';
        final String alt = message['alt'] ?? '';
        final String title = message['title'] ?? '';
        final String customAppBarTitle = message['customAppBarTitle'] ?? '';
        final String presentationStr = message['presentation'] ?? 'push';

        if (href.isEmpty) return;

        // Parse action and presentation
        final presentation = _parsePresentation(presentationStr);

        // Determine the display title: custom appbar title > title attribute > alt attribute > empty string
        final String displayTitle = customAppBarTitle.isNotEmpty
            ? customAppBarTitle
            : (title.isNotEmpty ? title : (alt.isNotEmpty ? alt : ''));

        // Navigate within the modal context
        navigate(
          context: context,
          url: href,
          title: displayTitle,
          action: action,
          presentation: presentation,
        );
      }
    } catch (e) {
      debugPrint('Error parsing bridge message: $e');
    }
  }

  void _handleBridgeMessageWithContext(dynamic message, BuildContext context) {
    try {
      // message is already the parsed JavaScript object
      final String actionStr = message['action'] ?? '';
      final bool isInModal = message['isInModal'] ?? false;

      if (actionStr == 'recede' || actionStr == 'close_modal') {
        Navigator.of(context).pop();
        return;
      }

      // Handle go_to_tab action
      final action = _parseAction(actionStr);
      if (action == RonelAction.goToTab) {
        final tabTitle = _extractTabTitleFromAction(actionStr);
        if (tabTitle != null) {
          debugPrint('Go to tab requested via bridge with context: $tabTitle');
          if (_onGoToTab != null) {
            _onGoToTab!(tabTitle);
          } else if (RonelAuth._globalGoToTabCallback != null) {
            debugPrint(
                'Using global go to tab callback via bridge with context');
            RonelAuth._globalGoToTabCallback!(tabTitle);
          } else {
            debugPrint(
                'No go to tab callback available via bridge with context');
          }
        }
        return;
      }

      // Handle navigation within modals
      if (isInModal && actionStr == 'advance') {
        final String href = message['href'] ?? '';
        final String alt = message['alt'] ?? '';
        final String title = message['title'] ?? '';
        final String customAppBarTitle = message['customAppBarTitle'] ?? '';
        final String presentationStr = message['presentation'] ?? 'push';

        if (href.isEmpty) return;

        // Parse action and presentation
        final presentation = _parsePresentation(presentationStr);

        // Determine the display title: custom appbar title > title attribute > alt attribute > empty string
        final String displayTitle = customAppBarTitle.isNotEmpty
            ? customAppBarTitle
            : (title.isNotEmpty ? title : (alt.isNotEmpty ? alt : ''));

        // Navigate within the modal context
        navigate(
          context: context,
          url: href,
          title: displayTitle,
          action: action,
          presentation: presentation,
        );
      }
    } catch (e) {
      debugPrint('Error parsing bridge message with context: $e');
    }
  }

  void _handleModalBridgeMessageWithModalContext(
      dynamic message, BuildContext modalContext) {
    try {
      // message is already the parsed JavaScript object
      final String actionStr = message['action'] ?? '';
      final bool isInModal = message['isInModal'] ?? false;

      // Handle close_modal and recede actions - use the modal context directly like the X button
      if (actionStr == 'recede' || actionStr == 'close_modal') {
        Navigator.of(modalContext).pop();
        return;
      }

      // Handle go_to_tab action
      final action = _parseAction(actionStr);
      if (action == RonelAction.goToTab) {
        final tabTitle = _extractTabTitleFromAction(actionStr);
        if (tabTitle != null) {
          debugPrint('Go to tab requested via modal bridge: $tabTitle');
          if (_onGoToTab != null) {
            _onGoToTab!(tabTitle);
          } else if (RonelAuth._globalGoToTabCallback != null) {
            debugPrint('Using global go to tab callback via modal bridge');
            RonelAuth._globalGoToTabCallback!(tabTitle);
          } else {
            debugPrint('No go to tab callback available via modal bridge');
          }
        }
        return;
      }

      // Handle navigation within modals
      if (isInModal && actionStr == 'advance') {
        final String href = message['href'] ?? '';
        final String alt = message['alt'] ?? '';
        final String title = message['title'] ?? '';
        final String customAppBarTitle = message['customAppBarTitle'] ?? '';
        final String presentationStr = message['presentation'] ?? 'push';

        if (href.isEmpty) return;

        // Parse action and presentation
        final presentation = _parsePresentation(presentationStr);

        // Determine the display title: custom appbar title > title attribute > alt attribute > empty string
        final String displayTitle = customAppBarTitle.isNotEmpty
            ? customAppBarTitle
            : (title.isNotEmpty ? title : (alt.isNotEmpty ? alt : ''));

        // Navigate within the modal context
        navigate(
          context: modalContext,
          url: href,
          title: displayTitle,
          action: action,
          presentation: presentation,
        );
      }
    } catch (e) {
      debugPrint('Error parsing modal bridge message with modal context: $e');
    }
  }

  RonelAction _parseAction(String actionStr) {
    debugPrint('Parsing action: "$actionStr"');

    // Handle go_to_tab[TabTitle] format
    if (actionStr.toLowerCase().startsWith('go_to_tab[') &&
        actionStr.endsWith(']')) {
      return RonelAction.goToTab;
    }

    switch (actionStr.toLowerCase()) {
      case 'replace':
        return RonelAction.replace;
      case 'recede':
        return RonelAction.recede;
      case 'close_modal':
        return RonelAction.closeModal;
      case 'logout':
        return RonelAction.logout;
      case 'advance':
      default:
        return RonelAction.advance;
    }
  }

  String? _extractTabTitleFromAction(String actionStr) {
    if (actionStr.toLowerCase().startsWith('go_to_tab[') &&
        actionStr.endsWith(']')) {
      final startIndex = actionStr.indexOf('[') + 1;
      final endIndex = actionStr.lastIndexOf(']');
      if (startIndex < endIndex) {
        return actionStr.substring(startIndex, endIndex);
      }
    }
    return null;
  }

  RonelPresentation _parsePresentation(String presentationStr) {
    switch (presentationStr.toLowerCase()) {
      case 'cover':
        return RonelPresentation.cover;
      case 'modal':
        return RonelPresentation.modal;
      case 'sheet':
        return RonelPresentation.sheet;
      case 'bottom_sheet':
        return RonelPresentation.bottomSheet;
      case 'push':
      default:
        return RonelPresentation.push;
    }
  }

  void navigate({
    required BuildContext context,
    required String url,
    required String title,
    RonelAction action = RonelAction.advance,
    RonelPresentation presentation = RonelPresentation.push,
  }) {
    debugPrint('Navigate called: url="$url", action="$action", presentation="$presentation"');
    
    switch (presentation) {
      case RonelPresentation.cover:
        _showCoverWebView(context, url, title);
        break;
      case RonelPresentation.modal:
        _showModalWebView(context, url, title);
        break;
      case RonelPresentation.bottomSheet:
        _showBottomSheetWebView(context, url, title);
        break;
      case RonelPresentation.sheet:
        _showSheetWebView(context, url, title);
        break;
      case RonelPresentation.push:
        _navigateToWebView(context, url, title, action);
        break;
    }
  }

  void _showModalWebView(BuildContext context, String url, String title) {
    debugPrint('_showModalWebView called: url="$url", title="$title"');
    
    if (_uiDesign == UIDesign.cupertino) {
      Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: true,
          barrierColor: CupertinoColors.black.withOpacity(0.54),
          pageBuilder: (modalContext, animation, secondaryAnimation) =>
              _ModalWebViewWidget(
            url: url,
            title: title,
            uiDesign: UIDesign.cupertino,
            appBarColor: _appBarColor,
            modalContext: modalContext,
            manager: this,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(
                  begin: 0.8,
                  end: 1.0,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutBack,
                )),
                child: child,
              ),
            );
          },
        ),
      );
    } else {
      Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: true,
          barrierColor: Colors.black54,
          pageBuilder: (modalContext, animation, secondaryAnimation) =>
              _ModalWebViewWidget(
            url: url,
            title: title,
            uiDesign: UIDesign.material,
            appBarColor: _appBarColor,
            modalContext: modalContext,
            manager: this,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(
                  begin: 0.8,
                  end: 1.0,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutBack,
                )),
                child: child,
              ),
            );
          },
        ),
      );
    }
  }

  void _showCoverWebView(BuildContext context, String url, String title) {
    final uiDesign = _uiDesign ?? UIDesign.material;
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        barrierDismissible: false,
        pageBuilder: (modalContext, animation, secondaryAnimation) => 
            _CoverWebViewWidget(
          url: url,
          title: title,
          uiDesign: uiDesign,
          modalContext: modalContext,
          manager: this,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOut,
            )),
            child: child,
          );
        },
      ),
    );
  }

  void _showSheetWebView(BuildContext context, String url, String title) {
    final uiDesign = _uiDesign ?? UIDesign.material;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) => _SheetWebViewWidget(
        url: url,
        title: title,
        uiDesign: uiDesign,
        appBarColor: _appBarColor,
        modalContext: modalContext,
        manager: this,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.3,
      ),
    ).then((_) {
      // This runs when the modal is dismissed (by any method)
      // Re-inject link interceptor on main WebView after modal closes
      Future.delayed(const Duration(milliseconds: 200), () {
        if (_controller != null) {
          debugPrint('Re-injecting link interceptor after bottom sheet modal close');
          _injectLinkInterceptor(_controller!);
        }
      });
    });
  }

  void _showBottomSheetWebView(BuildContext context, String url, String title) {
    final uiDesign = _uiDesign ?? UIDesign.material;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) => _SheetWebViewWidget(
        url: url,
        title: title,
        uiDesign: uiDesign,
        appBarColor: _appBarColor,
        modalContext: modalContext,
        manager: this,
        initialChildSize: 0.33,
        maxChildSize: 0.33,
        minChildSize: 0.2,
        isBottomSheet: true,
      ),
    ).then((_) {
      // This runs when the modal is dismissed (by any method)
      // Re-inject link interceptor on main WebView after modal closes
      Future.delayed(const Duration(milliseconds: 200), () {
        if (_controller != null) {
          debugPrint('Re-injecting link interceptor after bottom sheet modal close');
          _injectLinkInterceptor(_controller!);
        }
      });
    });
  }

  void _navigateToWebView(
      BuildContext context, String url, String title, RonelAction action) {
    debugPrint('_navigateToWebView called: url="$url", action="$action"');
    
    final uiDesign = _uiDesign ?? UIDesign.material;
    final route = uiDesign == UIDesign.cupertino
        ? CupertinoPageRoute(
            builder: (context) => _RonelDetailPage(
              url: url,
              title: title,
              uiDesign: uiDesign,
            ),
          )
        : MaterialPageRoute(
            builder: (context) => _RonelDetailPage(
              url: url,
              title: title,
              uiDesign: uiDesign,
            ),
          );

    switch (action) {
      case RonelAction.advance:
        debugPrint('Performing Navigator.push (advance)');
        Navigator.of(context).push(route);
        break;
      case RonelAction.replace:
        debugPrint('Performing Navigator.pushReplacement (replace)');
        Navigator.of(context).pushReplacement(route);
        break;
      case RonelAction.recede:
        Navigator.of(context).pop();
        break;
      case RonelAction.closeModal:
        Navigator.of(context).pop();
        break;
      case RonelAction.logout:
        // Handle logout action
        _handleLogout(context);
        break;
      case RonelAction.goToTab:
        // This should not happen in _navigateToWebView as goToTab is handled earlier
        debugPrint(
            'Warning: goToTab action reached _navigateToWebView, this should not happen');
        break;
    }
  }

  void _handleLogout(BuildContext context) {
    debugPrint('RonelManager: _handleLogout called');
    // Clear caches and cookies
    _clearWebViewCaches();

    // Call the global logout callback from RonelAuth if available
    if (RonelAuth._globalLogoutCallback != null) {
      debugPrint('RonelManager: Calling global logout callback');
      RonelAuth._globalLogoutCallback!();
    } else {
      debugPrint(
          'RonelManager: No global logout callback, trying instance callback');
      // Fallback: call the instance logout callback if provided
      _onLogout?.call();
    }
  }

  // This method will create an InAppWebViewController instance for modal views.
  // The lifecycle of this controller is tied to the modal's existence.
  // It's crucial not to reuse the main _controller here.
  void _injectLinkInterceptorForModal(InAppWebViewController controller) {
    controller.evaluateJavascript(source: '''
      (function() {
        // Prevent multiple injections for modal
        if (window.flutterModalLinkHandlerInjected) {
          return;
        }
        
        // Remove any existing event listeners to avoid duplicates
        if (window.flutterModalLinkHandler) {
          document.removeEventListener('click', window.flutterModalLinkHandler, true);
        }
        
        // Define the click handler for modal context
        window.flutterModalLinkHandler = function(event) {
          try {
            var target = event.target;
            
            // First check if the clicked element or any parent has data-ronel-action attribute
            var actionElement = null;
            var currentElement = target;
            var maxDepth = 10; // Prevent infinite loops
            var depth = 0;
            
            // Walk up the DOM tree to find an element with data-ronel-action or data-action
            while (currentElement && currentElement !== document && depth < maxDepth) {
              if (currentElement.getAttribute && (currentElement.getAttribute('data-ronel-action') || currentElement.getAttribute('data-action'))) {
                actionElement = currentElement;
                break;
              }
              currentElement = currentElement.parentElement;
              depth++;
            }
            
            // If we found an element with data-ronel-action, handle it
            if (actionElement) {
              event.preventDefault();
              event.stopPropagation();
              
              // Check for ronel bridge actions
              var action = actionElement.getAttribute('data-ronel-action') || actionElement.getAttribute('data-action');
              
              // All modal actions go through RonelBridge
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('RonelBridge', {
                  action: action || 'advance',
                  href: actionElement.href || actionElement.getAttribute('href') || '',
                  text: (actionElement.textContent || actionElement.innerText || '').substring(0, 500),
                  alt: actionElement.getAttribute('alt') || '',
                  title: actionElement.title || actionElement.getAttribute('title') || '',
                  customAppBarTitle: actionElement.getAttribute('data-ronel-appbartitle') || '',
                  presentation: actionElement.getAttribute('data-ronel-presentation') || actionElement.getAttribute('data-presentation') || 'push',
                  isInModal: true
                });
              }
              return;
            }
            
            // Fallback: check if it's an anchor tag without data-ronel-action
            var anchorElement = target;
            depth = 0;
            while (anchorElement && anchorElement.tagName !== 'A' && depth < maxDepth) {
              anchorElement = anchorElement.parentElement;
              depth++;
            }
            
            if (anchorElement && anchorElement.tagName === 'A' && !anchorElement.getAttribute('data-ronel-action') && !anchorElement.getAttribute('data-action')) {
              event.preventDefault();
              
              // Check for ronel bridge actions
              var action = anchorElement.getAttribute('data-ronel-action') || anchorElement.getAttribute('data-action');
              
              // All modal actions go through RonelBridge
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('RonelBridge', {
                  action: action || 'advance',
                  href: anchorElement.href,
                  text: (anchorElement.textContent || anchorElement.innerText || '').substring(0, 500),
                  alt: anchorElement.getAttribute('alt') || '',
                  title: anchorElement.title || '',
                  customAppBarTitle: anchorElement.getAttribute('data-ronel-appbartitle') || '',
                  presentation: anchorElement.getAttribute('data-ronel-presentation') || anchorElement.getAttribute('data-presentation') || 'push',
                  isInModal: true
                });
              }
            }
          } catch (error) {
            console.error('Error in flutterModalLinkHandler:', error);
          }
        };
        
        // Add the event listener
        document.addEventListener('click', window.flutterModalLinkHandler, true);
        
        // Mark as injected
        window.flutterModalLinkHandlerInjected = true;
        
      })();
    ''');
  }

  // Helper method to get navigation context
  BuildContext? _getNavigationContext() {
    return _context;
  }

  Future<void> refresh() async {
    if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
      return _refreshCompleter!.future;
    }

    _refreshCompleter = Completer<void>();
    await _controller!.reload();
    return _refreshCompleter!.future;
  }

  void dispose() {
    // InAppWebViewController instances are typically disposed when their containing widget is unmounted.
    // If _controller was explicitly created by RonelManager, it would be disposed here.
    // For now, we nullify the reference.
    _controller = null;
    _refreshCompleter = null;
    _pullToRefreshNotifier.dispose();
  }

  void setMainController(InAppWebViewController controller) {
    _controller = controller;
  }

  Future<void> _clearWebViewCaches() async {
    try {
      // Clear InAppWebView caches using instance methods if controller is available
      if (_controller != null) {
        await _controller!.clearCache();
      }

      // Clear cookies and other data using the correct API
      final cookieManager = CookieManager.instance();
      await cookieManager.deleteAllCookies();

      debugPrint('InAppWebView caches cleared on app start');
    } catch (e) {
      debugPrint('Error clearing InAppWebView caches: $e');
    }
  }
}

class Ronel extends StatelessWidget {
  final String url;
  final String? title;
  final String? appTitle;
  final Color? appBarColor;
  final String? uiDesign;
  final bool useAutoPlatformDetection;
  final ThemeData? materialTheme;
  final CupertinoThemeData? cupertinoTheme;

  const Ronel({
    super.key,
    required this.url,
    this.title,
    this.appTitle,
    this.appBarColor,
    this.uiDesign,
    this.useAutoPlatformDetection = true,
    this.materialTheme,
    this.cupertinoTheme,
  });

  UIDesign get _uiDesign {
    if (!useAutoPlatformDetection && uiDesign != null) {
      switch (uiDesign!.toLowerCase()) {
        case 'cupertino':
          return UIDesign.cupertino;
        case 'material':
        default:
          return UIDesign.material;
      }
    }

    // Auto-detect based on platform
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return UIDesign.cupertino;
      case TargetPlatform.android:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
      default:
        return UIDesign.material;
    }
  }

  @override
  Widget build(BuildContext context) {
    final String finalAppTitle = appTitle ?? title ?? 'WebView App';

    if (_uiDesign == UIDesign.cupertino) {
      return CupertinoApp(
        title: finalAppTitle,
        theme: cupertinoTheme ??
            const CupertinoThemeData(
              primaryColor: CupertinoColors.systemPurple,
              brightness: Brightness.light,
            ),
        home: _RonelWebView(
          title: title,
          uiDesign: _uiDesign,
          baseUrl: url,
          appBarColor: appBarColor,
        ),
      );
    } else {
      return MaterialApp(
        title: finalAppTitle,
        theme: materialTheme ??
            ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
              useMaterial3: true,
            ),
        home: _RonelWebView(
          title: title,
          uiDesign: _uiDesign,
          baseUrl: url,
          appBarColor: appBarColor,
        ),
      );
    }
  }
}

class _RonelWebView extends StatefulWidget {
  final String? title;
  final UIDesign uiDesign;
  final String baseUrl;
  final Color? appBarColor;

  const _RonelWebView({
    this.title,
    required this.uiDesign,
    required this.baseUrl,
    this.appBarColor,
  });

  @override
  State<_RonelWebView> createState() => _RonelWebViewState();
}

class _RonelWebViewState extends State<_RonelWebView> {
  late final RonelManager _manager;
  late PullToRefreshController _pullToRefreshController;
  InAppWebViewController? _webViewController;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _manager = RonelManager();
    _manager.initialize(
      baseUrl: widget.baseUrl,
      uiDesign: widget.uiDesign,
      appBarColor: widget.appBarColor,
    );

    _pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(
          color: widget.appBarColor ??
              (widget.uiDesign == UIDesign.cupertino
                  ? CupertinoColors.systemPurple
                  : Colors.deepPurple)),
      onRefresh: () async {
        if (_webViewController != null) {
          debugPrint('📱 RefreshIndicator triggered!');
          await _webViewController!.reload();
          _safeEndRefreshing();
        }
      },
    );
  }

  @override
  void dispose() {
    _manager.dispose();
    _pullToRefreshController.dispose();
    super.dispose();
  }

  void _safeEndRefreshing() {
    try {
      if (mounted) {
        _pullToRefreshController.endRefreshing();
      }
    } catch (e) {
      // Silently handle disposed controller errors
      debugPrint('PullToRefreshController already disposed: $e');
    }
  }

  Future<void> _checkSessionExpiration(String currentUrl) async {
    // Only check if we're using RonelAuth and have a global auth URL
    if (RonelAuth._globalAuthUrl == null) return;

    try {
      // Check if user is currently authenticated
      final prefs = await SharedPreferences.getInstance();
      final isAuthenticated = prefs.getBool('isAuthenticated') ?? false;

      if (!isAuthenticated) return; // Not authenticated, no need to check

      // Compare current URL with auth URL - if they match, session expired
      final Uri currentUri = Uri.parse(currentUrl);
      final Uri authUri = Uri.parse(RonelAuth._globalAuthUrl!);

      // Check if the current URL matches the auth URL (ignoring query parameters)
      bool urlsMatch = currentUri.scheme == authUri.scheme &&
          currentUri.host == authUri.host &&
          currentUri.port == authUri.port &&
          currentUri.path == authUri.path;

      if (urlsMatch) {
        debugPrint(
            '📱 Main WebView detected session expiration - current URL matches auth URL');

        // Call logout to clear authentication and trigger re-auth
        if (RonelAuth._globalLogoutCallback != null) {
          debugPrint(
              '📱 Main WebView calling logout due to session expiration');
          RonelAuth._globalLogoutCallback!();
        }
      }
    } catch (e) {
      debugPrint('📱 Main WebView error checking session expiration: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Store context in the manager for navigation
    _manager.context = context;

    Widget webViewWidget = InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.baseUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: true,
        javaScriptEnabled: true,
        useHybridComposition: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        iframeAllow: "camera; microphone",
        iframeAllowFullscreen: true,
        allowsLinkPreview: false,
        disableLongPressContextMenuOnLinks: true,
        supportZoom: false,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: '''
            (function() {
              // Create style element immediately
              var ronelStyle = document.createElement('style');
              ronelStyle.id = 'ronel-hidden-style';
              ronelStyle.type = 'text/css';
              ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
              
              // Function to inject CSS
              function injectCSS() {
                var head = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
                if (head && !document.getElementById('ronel-hidden-style')) {
                  head.insertBefore(ronelStyle, head.firstChild);
                }
              }
              
              // Try to inject immediately
              injectCSS();
              
              // Also inject when DOM is ready
              if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', injectCSS);
              }
            })();
          ''',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      pullToRefreshController: _pullToRefreshController,
      onWebViewCreated: (controller) {
        _webViewController = controller;
        _manager.setMainController(
            controller); // Set the main controller in the manager
        controller.addJavaScriptHandler(
            handlerName: 'FlutterNavigation',
            callback: (args) {
              // args[0] is already the parsed JavaScript object, no need to jsonEncode
              _manager._handleLinkClick(args[0]);
            });
        controller.addJavaScriptHandler(
            handlerName: 'RonelBridge',
            callback: (args) {
              _manager._handleBridgeMessage(args[0]);
            });
        controller.addJavaScriptHandler(
            handlerName:
                'RonelPullRefreshStatus', // Renamed from RonelPullRefresh
            callback: (args) {
              _manager._handlePullRefreshMessage(args[0]);
            });
      },
      onLoadStart: (controller, url) {
        // Show loading spinner when starting to load new page
        if (mounted) {
          setState(() {
            _isLoading = true;
          });
        }
      },
      onLoadStop: (controller, url) async {
        _manager._injectLinkInterceptor(controller);
        _manager._checkPullToRefreshAttribute(controller);

        // Check for session expiration when URL loads
        if (url != null) {
          await _checkSessionExpiration(url.toString());
        }

        _safeEndRefreshing();
        
        // Hide loading spinner
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      },
      onUpdateVisitedHistory: (controller, url, androidIsReload) async {
        // Check for session expiration on URL changes
        if (url != null) {
          await _checkSessionExpiration(url.toString());
        }
      },
      onReceivedError: (controller, request, error) {
        debugPrint('Main WebView Error: ${error.description}');
        _safeEndRefreshing();
        
        // Hide loading spinner on error
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      },
      onProgressChanged: (controller, progress) {
        if (progress == 100) {
          // Page loading complete
          if (mounted) {
            setState(() {
              _isLoading = false;
            });
          }
        }
      },
    );

    if (widget.uiDesign == UIDesign.cupertino) {
      return CupertinoPageScaffold(
        navigationBar: widget.title != null
            ? CupertinoNavigationBar(
                backgroundColor:
                    _manager._appBarColor ?? CupertinoColors.systemBackground,
                middle: Text(widget.title!),
              )
            : null,
        child: widget.title != null
            ? ValueListenableBuilder<bool>(
                valueListenable: _manager.pullToRefreshNotifier,
                builder: (context, isPullToRefreshEnabled, child) {

                  Widget content = Stack(
                    children: [
                      webViewWidget, // InAppWebView handles pull-to-refresh internally via controller
                      if (_isLoading)
                        Container(
                          color: CupertinoColors.systemBackground,
                          child: Center(
                            child: CupertinoActivityIndicator(
                              radius: 16,
                            ),
                          ),
                        ),
                    ],
                  );

                  return content;
                },
              )
            : SafeArea(
                child: ValueListenableBuilder<bool>(
                  valueListenable: _manager.pullToRefreshNotifier,
                  builder: (context, isPullToRefreshEnabled, child) {
                    Widget content = Stack(
                      children: [
                        webViewWidget, // InAppWebView handles pull-to-refresh internally via controller
                        if (_isLoading)
                          Container(
                            color: CupertinoColors.systemBackground,
                            child: Center(
                              child: CupertinoActivityIndicator(
                                radius: 16,
                              ),
                            ),
                          ),
                      ],
                    );

                    // Add a visual debug indicator
                    return content;
                  },
                ),
              ),
      );
    } else {
      return Scaffold(
        appBar: widget.title != null
            ? AppBar(
                backgroundColor: _manager._appBarColor ??
                    Theme.of(context).colorScheme.inversePrimary,
                title: Text(widget.title!),
              )
            : null,
        body: widget.title != null
            ? ValueListenableBuilder<bool>(
                valueListenable: _manager.pullToRefreshNotifier,
                builder: (context, isPullToRefreshEnabled, child) {
                  Widget content = Stack(
                    children: [
                      webViewWidget, // InAppWebView handles pull-to-refresh internally via controller
                      if (_isLoading)
                        Container(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: Center(
                            child: CircularProgressIndicator(),
                          ),
                        ),
                    ],
                  );

                  return content;
                },
              )
            : SafeArea(
                child: ValueListenableBuilder<bool>(
                  valueListenable: _manager.pullToRefreshNotifier,
                  builder: (context, isPullToRefreshEnabled, child) {
                    Widget content = Stack(
                      children: [
                        webViewWidget, // InAppWebView handles pull-to-refresh internally via controller
                        if (_isLoading)
                          Container(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            child: Center(
                              child: CircularProgressIndicator(),
                            ),
                          ),
                      ],
                    );

                    return content;
                  },
                ),
              ),
      );
    }
  }
}

class _RonelDetailPage extends StatefulWidget {
  final String url;
  final String title;
  final UIDesign uiDesign;

  const _RonelDetailPage({
    required this.url,
    required this.title,
    required this.uiDesign,
  });

  @override
  State<_RonelDetailPage> createState() => _RonelDetailPageState();
}

class _RonelDetailPageState extends State<_RonelDetailPage> {
  late InAppWebViewController _webViewController;
  late final RonelManager _manager;
  bool isLoading = true;
  bool _pullToRefreshEnabled = true; // Default to enabled
  late PullToRefreshController _pullToRefreshController;

  @override
  void initState() {
    super.initState();
    _manager = RonelManager();
    isLoading = true; // Set initial loading state

    _pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(
          color: _manager._appBarColor ??
              (widget.uiDesign == UIDesign.cupertino
                  ? CupertinoColors.systemPurple
                  : Colors.deepPurple)),
      onRefresh: () async {
        debugPrint('📱 Detail Page RefreshIndicator triggered!');
        await _webViewController.reload();
        _safeEndRefreshing();
      },
    );
  }

  @override
  void dispose() {
    _pullToRefreshController.dispose();
    super.dispose();
  }

  void _safeEndRefreshing() {
    try {
      if (mounted) {
        _pullToRefreshController.endRefreshing();
      }
    } catch (e) {
      // Silently handle disposed controller errors
      debugPrint('PullToRefreshController already disposed: $e');
    }
  }

  Future<void> _checkSessionExpiration(String currentUrl) async {
    // Only check if we're using RonelAuth and have a global auth URL
    if (RonelAuth._globalAuthUrl == null) return;

    try {
      // Check if user is currently authenticated
      final prefs = await SharedPreferences.getInstance();
      final isAuthenticated = prefs.getBool('isAuthenticated') ?? false;

      if (!isAuthenticated) return; // Not authenticated, no need to check

      // Compare current URL with auth URL - if they match, session expired
      final Uri currentUri = Uri.parse(currentUrl);
      final Uri authUri = Uri.parse(RonelAuth._globalAuthUrl!);

      // Check if the current URL matches the auth URL (ignoring query parameters)
      bool urlsMatch = currentUri.scheme == authUri.scheme &&
          currentUri.host == authUri.host &&
          currentUri.port == authUri.port &&
          currentUri.path == authUri.path;

      if (urlsMatch) {
        debugPrint(
            '📱 Detail Page detected session expiration - current URL matches auth URL');

        // Call logout to clear authentication and trigger re-auth
        if (RonelAuth._globalLogoutCallback != null) {
          debugPrint('📱 Detail Page calling logout due to session expiration');
          RonelAuth._globalLogoutCallback!();
        }
      }
    } catch (e) {
      debugPrint('📱 Detail Page error checking session expiration: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    _manager.context = context; // Pass context to manager

    Widget webViewWidget = InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: true,
        javaScriptEnabled: true,
        useHybridComposition: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        iframeAllow: "camera; microphone",
        iframeAllowFullscreen: true,
        allowsLinkPreview: false,
        disableLongPressContextMenuOnLinks: true,
        supportZoom: false,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: '''
            (function() {
              // Create style element immediately
              var ronelStyle = document.createElement('style');
              ronelStyle.id = 'ronel-hidden-style';
              ronelStyle.type = 'text/css';
              ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
              
              // Function to inject CSS
              function injectCSS() {
                var head = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
                if (head && !document.getElementById('ronel-hidden-style')) {
                  head.insertBefore(ronelStyle, head.firstChild);
                }
              }
              
              // Try to inject immediately
              injectCSS();
              
              // Also inject when DOM is ready
              if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', injectCSS);
              }
            })();
          ''',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      pullToRefreshController: _pullToRefreshController,
      onWebViewCreated: (controller) {
        _webViewController = controller;
        controller.addJavaScriptHandler(
            handlerName: 'FlutterNavigation',
            callback: (args) {
              _handleDetailPageLinkClick(args[0]);
            });
        controller.addJavaScriptHandler(
            handlerName: 'RonelBridge',
            callback: (args) {
              _handleDetailPageBridgeMessage(args[0]);
            });
        controller.addJavaScriptHandler(
            handlerName:
                'RonelPullRefreshStatus', // Renamed from RonelPullRefresh
            callback: (args) {
              _handleDetailPagePullRefreshMessage(args[0]);
            });
      },
      onLoadStart: (controller, url) {
        setState(() {
          isLoading = true;
        });
      },
      onLoadStop: (controller, url) async {
        setState(() {
          isLoading = false;
        });
        
        // Inject link interceptor for detail page
        _manager._injectLinkInterceptor(controller);
        
        // Check pull-to-refresh attribute
        await controller.evaluateJavascript(source: '''
          // Check if body has data-ronel-pull-refresh attribute
          var body = document.body;
          if (body) {
            var pullRefreshAttr = body.getAttribute('data-ronel-pull-refresh');
            if (pullRefreshAttr !== null) {
              // Send the attribute value to Flutter
              window.flutter_inappwebview.callHandler('RonelPullRefreshStatus', {
                pullToRefresh: pullRefreshAttr
              });
            }
          }
        ''');

        // Check for session expiration when URL loads
        if (url != null) {
          await _checkSessionExpiration(url.toString());
        }

        _safeEndRefreshing();
      },
      onUpdateVisitedHistory: (controller, url, androidIsReload) async {
        // Check for session expiration on URL changes
        if (url != null) {
          await _checkSessionExpiration(url.toString());
        }
      },
      onReceivedError: (controller, request, error) {
        debugPrint('Detail page WebView error: ${error.description}');
        setState(() {
          isLoading = false;
        });
        _safeEndRefreshing();
      },
      onProgressChanged: (controller, progress) {
        if (progress == 100) {
          _safeEndRefreshing();
        }
      },
    );

    Widget body = Stack(
      children: [
        webViewWidget,
        if (isLoading)
          Center(
            child: widget.uiDesign == UIDesign.cupertino
                ? const CupertinoActivityIndicator()
                : const CircularProgressIndicator(),
          ),
      ],
    );

    if (widget.uiDesign == UIDesign.cupertino) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          backgroundColor:
              _manager._appBarColor ?? CupertinoColors.systemBackground,
          middle: Text(
            widget.title,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        child: body,
      );
    } else {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: _manager._appBarColor ??
              Theme.of(context).colorScheme.inversePrimary,
          title: Text(
            widget.title,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: body,
      );
    }
  }

  void _handleDetailPageLinkClick(dynamic linkData) {
    try {
      // linkData is already the parsed JavaScript object
      final String href = linkData['href'] ?? '';
      final String alt = linkData['alt'] ?? '';
      final bool isModal = linkData['isModal'] ?? false;
      final String title = linkData['title'] ?? '';
      final String customAppBarTitle = linkData['customAppBarTitle'] ?? '';
      final String actionStr = linkData['action'] ?? 'advance';
      final String presentationStr = linkData['presentation'] ?? 'push';

      debugPrint('Detail page link clicked: href="$href", action="$actionStr", presentation="$presentationStr", isModal="$isModal"');

      // Parse action first
      final action = _manager._parseAction(actionStr);

      // Handle actions that don't require URL navigation
      if (action == RonelAction.recede || action == RonelAction.closeModal) {
        Navigator.of(context).pop();
        return;
      }

      // Handle go_to_tab action
      if (action == RonelAction.goToTab) {
        final tabTitle = _manager._extractTabTitleFromAction(actionStr);
        if (tabTitle != null) {
          debugPrint('Detail page: Go to tab requested: $tabTitle');
          if (RonelAuth._globalGoToTabCallback != null) {
            debugPrint('Detail page: Using global go to tab callback');
            RonelAuth._globalGoToTabCallback!(tabTitle);
          } else {
            debugPrint('Detail page: No go to tab callback available');
          }
        }
        return;
      }

      if (href.isEmpty) return;

      // Parse presentation - check both isModal flag and presentation string
      final presentation = (isModal || presentationStr.toLowerCase() == 'modal')
          ? RonelPresentation.modal
          : _manager._parsePresentation(presentationStr);

      debugPrint('Detail page parsed presentation: $presentation, parsed action: $action');

      // Determine the display title: custom appbar title > title attribute > alt attribute > empty string
      final String displayTitle = customAppBarTitle.isNotEmpty
          ? customAppBarTitle
          : (title.isNotEmpty ? title : (alt.isNotEmpty ? alt : ''));

      // Navigate using the current context
      _manager.navigate(
        context: context,
        url: href,
        title: displayTitle,
        action: action,
        presentation: presentation,
      );
    } catch (e) {
      debugPrint('Error parsing link data in detail page: $e');
    }
  }

  void _handleDetailPageBridgeMessage(dynamic message) {
    try {
      // message is already the parsed JavaScript object
      final String actionStr = message['action'] ?? '';

      if (actionStr == 'recede' || actionStr == 'close_modal') {
        Navigator.of(context).pop();
        return;
      }

      // Handle other bridge messages if needed
      // For now, we can delegate to the main handler but with explicit context
      _manager._handleBridgeMessageWithContext(message, context);
    } catch (e) {
      debugPrint('Error parsing bridge message in detail page: $e');
    }
  }

  void _handleDetailPagePullRefreshMessage(dynamic message) {
    try {
      // message is already the parsed JavaScript object
      final String pullToRefreshStr = message['pullToRefresh'] ?? '';

      // Parse the attribute value - "true" enables, anything else disables
      setState(() {
        _pullToRefreshEnabled = pullToRefreshStr.toLowerCase() == 'true';
      });

      debugPrint(
          'Detail page pull-to-refresh ${_pullToRefreshEnabled ? 'enabled' : 'disabled'} from HTML attribute');
    } catch (e) {
      debugPrint('Error parsing pull-to-refresh message in detail page: $e');
      // Default to enabled on parse error
      setState(() {
        _pullToRefreshEnabled = true;
      });
    }
  }
}

// Tab functionality - Multi-tab Ronel App
class RonelTabApp extends StatefulWidget {
  final List<RonelTab>? tabs;
  final String? configUrl;
  final String? appTitle;
  final Color? appBarColor;
  final String? uiDesign;
  final bool useAutoPlatformDetection;
  final ThemeData? materialTheme;
  final CupertinoThemeData? cupertinoTheme;

  const RonelTabApp({
    super.key,
    this.tabs,
    this.configUrl,
    this.appTitle,
    this.appBarColor,
    this.uiDesign,
    this.useAutoPlatformDetection = true,
    this.materialTheme,
    this.cupertinoTheme,
  })  : assert(tabs != null || configUrl != null,
            'Either tabs or configUrl must be provided'),
        assert(!(tabs != null && configUrl != null),
            'Cannot provide both tabs and configUrl');

  @override
  State<RonelTabApp> createState() => _RonelTabAppState();
}

class _RonelTabAppState extends State<RonelTabApp> {
  List<RonelTab>? _tabs;
  bool _isLoading = false;
  String? _error;

  UIDesign get _uiDesign {
    if (!widget.useAutoPlatformDetection && widget.uiDesign != null) {
      switch (widget.uiDesign!.toLowerCase()) {
        case 'cupertino':
          return UIDesign.cupertino;
        case 'material':
        default:
          return UIDesign.material;
      }
    }

    // Auto-detect based on platform
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return UIDesign.cupertino;
      case TargetPlatform.android:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
      default:
        return UIDesign.material;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.tabs != null) {
      _tabs = widget.tabs;
    } else if (widget.configUrl != null) {
      _loadConfigFromUrl();
    }
  }

  Future<void> _loadConfigFromUrl() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await http.get(Uri.parse(widget.configUrl!));

      if (response.statusCode == 200) {
        final configData = jsonDecode(response.body);
        final List<RonelTab> tabs = await _parseConfigToTabs(configData);

        setState(() {
          _tabs = tabs;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load configuration: ${response.statusCode}';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading configuration: $e';
        _isLoading = false;
      });
    }
  }

  Future<List<RonelTab>> _parseConfigToTabs(Map<String, dynamic> config) async {
    final List<dynamic> tabsData = config['tabs'] ?? [];

    return tabsData.map<RonelTab>((tabData) {
      return RonelTab(
        url: tabData['url'] ?? '',
        title: tabData['title'] ?? '',
        icon: _getIconFromString(tabData['icon'] ?? 'home'),
        activeIcon: _getIconFromString(
            tabData['activeIcon'] ?? tabData['icon'] ?? 'home'),
      );
    }).toList();
  }

  IconData _getIconFromString(String iconName) {
    // Map common icon names to IconData
    final Map<String, IconData> iconMap = {
      'home': Icons.home,
      'home_filled': Icons.home_filled,
      'info_outline': Icons.info_outline,
      'info': Icons.info,
      'contact_mail_outlined': Icons.contact_mail_outlined,
      'contact_mail': Icons.contact_mail,
      'description': Icons.description,
      'flutter_dash_outlined': Icons.flutter_dash_outlined,
      'flutter_dash': Icons.flutter_dash,
      'settings': Icons.settings,
      'settings_outlined': Icons.settings_outlined,
      'person': Icons.person,
      'person_outline': Icons.person_outline,
      'favorite': Icons.favorite,
      'favorite_outline': Icons.favorite_outline,
      'star': Icons.star,
      'star_outline': Icons.star_outline,
      'business': Icons.business,
      'business_outlined': Icons.business_outlined,
      'shopping_cart': Icons.shopping_cart,
      'shopping_cart_outlined': Icons.shopping_cart_outlined,
    };

    return iconMap[iconName] ?? Icons.tab;
  }

  Widget _buildLoadingWidget() {
    return _uiDesign == UIDesign.cupertino
        ? const CupertinoActivityIndicator()
        : const CircularProgressIndicator();
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _uiDesign == UIDesign.cupertino
                ? CupertinoIcons.exclamationmark_triangle
                : Icons.error,
            size: 48,
            color: _uiDesign == UIDesign.cupertino
                ? CupertinoColors.systemRed
                : Colors.red,
          ),
          const SizedBox(height: 16),
          Text(
            _error ?? 'Unknown error',
            textAlign: TextAlign.center,
            style: _uiDesign == UIDesign.cupertino
                ? CupertinoTheme.of(context).textTheme.textStyle
                : Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          if (_uiDesign == UIDesign.cupertino)
            CupertinoButton(
              onPressed: _loadConfigFromUrl,
              child: const Text('Retry'),
            )
          else
            ElevatedButton(
              onPressed: _loadConfigFromUrl,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String finalAppTitle = widget.appTitle ?? 'Ronel App';

    Widget homeWidget;

    if (_isLoading) {
      homeWidget = Scaffold(
        body: Center(child: _buildLoadingWidget()),
      );
    } else if (_error != null) {
      homeWidget = Scaffold(
        body: _buildErrorWidget(),
      );
    } else if (_tabs != null && _tabs!.isNotEmpty) {
      homeWidget = _RonelTabScaffold(
        tabs: _tabs!,
        uiDesign: _uiDesign,
        appBarColor: widget.appBarColor,
      );
    } else {
      homeWidget = Scaffold(
        body: Center(
          child: Text(
            'No tabs available',
            style: _uiDesign == UIDesign.cupertino
                ? CupertinoTheme.of(context).textTheme.textStyle
                : Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }

    if (_uiDesign == UIDesign.cupertino) {
      return CupertinoApp(
        title: finalAppTitle,
        theme: widget.cupertinoTheme ??
            const CupertinoThemeData(
              primaryColor: CupertinoColors.systemPurple,
              brightness: Brightness.light,
            ),
        home: homeWidget,
      );
    } else {
      return MaterialApp(
        title: finalAppTitle,
        theme: widget.materialTheme ??
            ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
              useMaterial3: true,
            ),
        home: homeWidget,
      );
    }
  }
}

class RonelTab {
  final String url;
  final String title;
  final IconData icon;
  final IconData? activeIcon;

  const RonelTab({
    required this.url,
    required this.title,
    required this.icon,
    this.activeIcon,
  });
}

class _RonelTabScaffold extends StatefulWidget {
  final List<RonelTab> tabs;
  final UIDesign uiDesign;
  final Color? appBarColor;

  const _RonelTabScaffold({
    required this.tabs,
    required this.uiDesign,
    this.appBarColor,
  });

  @override
  State<_RonelTabScaffold> createState() => _RonelTabScaffoldState();
}

class _RonelTabScaffoldState extends State<_RonelTabScaffold> {
  int _currentIndex = 0;
  late List<RonelManager> _managers;
  final List<InAppWebViewController?> _tabWebControllers =
      List.filled(5, null); // Max 5 tabs, adjust as needed

  @override
  void initState() {
    super.initState();
    // Create a separate RonelManager for each tab
    _managers = widget.tabs.map((tab) {
      final manager = RonelManager();
      manager.initialize(
        baseUrl: tab.url,
        uiDesign: widget.uiDesign,
        appBarColor: widget.appBarColor,
      );
      // Set up tab switching callback
      manager.onGoToTab = _switchToTabByTitle;
      return manager;
    }).toList();

    // Set up global tab switching callback for detail pages and modals
    RonelAuth._globalGoToTabCallback = _switchToTabByTitle;
  }

  void _switchToTabByTitle(String tabTitle) {
    final targetIndex = widget.tabs
        .indexWhere((tab) => tab.title.toLowerCase() == tabTitle.toLowerCase());
    if (targetIndex >= 0 && targetIndex != _currentIndex) {
      debugPrint('Switching to tab: $tabTitle (index: $targetIndex)');
      setState(() {
        _currentIndex = targetIndex;
      });
    } else if (targetIndex < 0) {
      debugPrint('Tab not found: $tabTitle');
    } else {
      debugPrint('Already on tab: $tabTitle');
    }
  }

  @override
  void dispose() {
    // Clean up all managers
    for (final manager in _managers) {
      manager.dispose();
    }
    // Clean up global callback
    if (RonelAuth._globalGoToTabCallback == _switchToTabByTitle) {
      RonelAuth._globalGoToTabCallback = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Update current manager's context
    if (_managers.isNotEmpty) {
      _managers[_currentIndex].context = context;
    }

    if (widget.uiDesign == UIDesign.cupertino) {
      return CupertinoPageScaffold(
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: _managers.asMap().entries.map((entry) {
                  final index = entry.key;
                  final manager = entry.value;
                  return CupertinoPageScaffold(
                    navigationBar: CupertinoNavigationBar(
                      backgroundColor: widget.appBarColor ??
                          CupertinoColors.systemBackground,
                      middle: Text(widget.tabs[index].title),
                    ),
                    child: _RonelTabContent(
                      manager: manager,
                      uiDesign: widget.uiDesign,
                      initialUrl: widget.tabs[index].url, // Pass initial URL
                      tabIndex: index,
                      onWebViewCreated: (controller) {
                        _tabWebControllers[index] = controller;
                        manager.setMainController(controller);
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
            CupertinoTabBar(
              currentIndex: _currentIndex,
              onTap: (index) {
                setState(() {
                  _currentIndex = index;
                  // Note: Don't reload URL - IndexedStack preserves WebView state!
                  // The WebView should already be loaded and maintained in memory
                });
              },
              items: widget.tabs
                  .map((tab) => BottomNavigationBarItem(
                        icon: Icon(tab.icon),
                        activeIcon: Icon(tab.activeIcon ?? tab.icon),
                        label: tab.title,
                      ))
                  .toList(),
            ),
          ],
        ),
      );
    } else {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: widget.appBarColor ??
              Theme.of(context).colorScheme.inversePrimary,
          title: Text(widget.tabs[_currentIndex].title),
        ),
        body: IndexedStack(
          index: _currentIndex,
          children: _managers.asMap().entries.map((entry) {
            final index = entry.key;
            final manager = entry.value;
            return _RonelTabContent(
              manager: manager,
              uiDesign: widget.uiDesign,
              initialUrl: widget.tabs[index].url, // Pass initial URL
              tabIndex: index,
              onWebViewCreated: (controller) {
                _tabWebControllers[index] = controller;
                manager.setMainController(controller);
              },
            );
          }).toList(),
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
              // Note: Don't reload URL - IndexedStack preserves WebView state!
              // The WebView should already be loaded and maintained in memory
            });
          },
          type: BottomNavigationBarType.fixed,
          items: widget.tabs
              .map((tab) => BottomNavigationBarItem(
                    icon: Icon(tab.icon),
                    activeIcon: Icon(tab.activeIcon ?? tab.icon),
                    label: tab.title,
                  ))
              .toList(),
        ),
      );
    }
  }
}

class _RonelTabContent extends StatefulWidget {
  final RonelManager manager;
  final UIDesign uiDesign;
  final String initialUrl; // Added initialUrl
  final int tabIndex; // Added tabIndex for debugging
  final Function(InAppWebViewController)
      onWebViewCreated; // Callback to pass controller

  const _RonelTabContent({
    required this.manager,
    required this.uiDesign,
    required this.initialUrl,
    required this.tabIndex,
    required this.onWebViewCreated,
  });

  @override
  State<_RonelTabContent> createState() => _RonelTabContentState();
}

class _RonelTabContentState extends State<_RonelTabContent>
    with AutomaticKeepAliveClientMixin {
  InAppWebViewController? _webViewController;
  late PullToRefreshController _pullToRefreshController;

  @override
  bool get wantKeepAlive => true; // This preserves the state

  @override
  void initState() {
    super.initState();
    _pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(
          color: widget.manager._appBarColor ??
              (widget.uiDesign == UIDesign.cupertino
                  ? CupertinoColors.systemPurple
                  : Colors.deepPurple)),
      onRefresh: () async {
        if (_webViewController != null) {
          // Check if pull-to-refresh is actually enabled before proceeding
          if (widget.manager.pullToRefreshNotifier.value) {
            debugPrint('📱 Tab ${widget.tabIndex} RefreshIndicator triggered!');
            await _webViewController!.reload();
          } else {
            debugPrint(
                '📱 Tab ${widget.tabIndex} Pull-to-refresh disabled, ignoring gesture');
          }
          _safeEndRefreshing();
        }
      },
    );

    // Listen to pull-to-refresh changes and update the controller dynamically
    widget.manager.pullToRefreshNotifier.addListener(_updatePullToRefreshState);
  }

  void _updatePullToRefreshState() {
    // Note: InAppWebView doesn't support dynamic pull-to-refresh controller changes
    // The controller is set once during initialization and cannot be changed dynamically
    // This is a limitation of the flutter_inappwebview plugin
    // For now, we always enable the controller and handle state in the onRefresh callback
  }

  @override
  void dispose() {
    widget.manager.pullToRefreshNotifier
        .removeListener(_updatePullToRefreshState);
    _pullToRefreshController.dispose();
    super.dispose();
  }

  void _safeEndRefreshing() {
    try {
      if (mounted) {
        _pullToRefreshController.endRefreshing();
      }
    } catch (e) {
      // Silently handle disposed controller errors
      debugPrint('PullToRefreshController already disposed: $e');
    }
  }

  Future<void> _checkSessionExpiration(String currentUrl) async {
    // Only check if we're using RonelAuth and have a global auth URL
    if (RonelAuth._globalAuthUrl == null) return;

    try {
      // Check if user is currently authenticated
      final prefs = await SharedPreferences.getInstance();
      final isAuthenticated = prefs.getBool('isAuthenticated') ?? false;

      if (!isAuthenticated) return; // Not authenticated, no need to check

      // Compare current URL with auth URL - if they match, session expired
      final Uri currentUri = Uri.parse(currentUrl);
      final Uri authUri = Uri.parse(RonelAuth._globalAuthUrl!);

      // Check if the current URL matches the auth URL (ignoring query parameters)
      bool urlsMatch = currentUri.scheme == authUri.scheme &&
          currentUri.host == authUri.host &&
          currentUri.port == authUri.port &&
          currentUri.path == authUri.path;

      if (urlsMatch) {
        debugPrint(
            '📱 Tab ${widget.tabIndex} detected session expiration - current URL matches auth URL');

        // Call logout to clear authentication and trigger re-auth
        if (RonelAuth._globalLogoutCallback != null) {
          debugPrint(
              '📱 Tab ${widget.tabIndex} calling logout due to session expiration');
          RonelAuth._globalLogoutCallback!();
        }
      }
    } catch (e) {
      debugPrint(
          '📱 Tab ${widget.tabIndex} error checking session expiration: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    // Return InAppWebView directly - no rebuilding, preserves state perfectly
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: true,
        javaScriptEnabled: true,
        useHybridComposition: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        iframeAllow: "camera; microphone",
        iframeAllowFullscreen: true,
        allowsLinkPreview: false,
        disableLongPressContextMenuOnLinks: true,
        supportZoom: false,
        // Crucial for IndexedStack: Keep the WebView alive even when not visible.
        // This prevents reloading when switching tabs.
        preferredContentMode: UserPreferredContentMode.RECOMMENDED,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: '''
            (function() {
              // Create style element immediately
              var ronelStyle = document.createElement('style');
              ronelStyle.id = 'ronel-hidden-style';
              ronelStyle.type = 'text/css';
              ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
              
              // Function to inject CSS
              function injectCSS() {
                var head = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
                if (head && !document.getElementById('ronel-hidden-style')) {
                  head.insertBefore(ronelStyle, head.firstChild);
                }
              }
              
              // Try to inject immediately
              injectCSS();
              
              // Also inject when DOM is ready
              if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', injectCSS);
              }
            })();
          ''',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      pullToRefreshController:
          _pullToRefreshController, // Always use the controller
      onWebViewCreated: (controller) {
        _webViewController = controller;
        widget.onWebViewCreated(controller); // Pass controller back to parent

        // Register JavaScript handlers for this tab's WebView
        controller.addJavaScriptHandler(
            handlerName: 'FlutterNavigation',
            callback: (args) {
              widget.manager._handleLinkClick(args[0]);
            });
        controller.addJavaScriptHandler(
            handlerName: 'RonelBridge',
            callback: (args) {
              widget.manager._handleBridgeMessage(args[0]);
            });
        controller.addJavaScriptHandler(
            handlerName: 'RonelPullRefreshStatus',
            callback: (args) {
              widget.manager._handlePullRefreshMessage(args[0]);
            });
      },
      onLoadStop: (controller, url) async {
        widget.manager._injectLinkInterceptor(controller);
        widget.manager._checkPullToRefreshAttribute(controller);

        // Check for session expiration when URL loads
        if (url != null) {
          await _checkSessionExpiration(url.toString());
        }

        _safeEndRefreshing();
      },
      onUpdateVisitedHistory: (controller, url, androidIsReload) async {
        // Check for session expiration on URL changes
        if (url != null) {
          await _checkSessionExpiration(url.toString());
        }
      },
      onReceivedError: (controller, request, error) {
        debugPrint(
            'Tab ${widget.tabIndex} WebView Error: ${error.description}');
        _safeEndRefreshing();
      },
      onProgressChanged: (controller, progress) {
        if (progress == 100) {
          _safeEndRefreshing();
        }
      },
    );
  }
}

// RonelAuth widget for authentication flow
class RonelAuth extends StatefulWidget {
  final String authUrl;
  final String tokenParamName;
  final String authTokenParamName;
  final String? uiDesign;
  final Color? appBarColor;
  final bool useAutoPlatformDetection;
  final bool showAppBar;
  final String title;
  final bool showCancelButton;
  final Widget loadAfterAuth;
  final VoidCallback? onAuthError;
  final VoidCallback? onTokenExtractionError;
  final Duration authTimeout;

  const RonelAuth({
    super.key,
    required this.authUrl,
    required this.tokenParamName,
    required this.loadAfterAuth,
    this.showAppBar = true,
    this.title = 'Authentication',
    this.showCancelButton = false,
    this.authTokenParamName = 'authToken',
    this.uiDesign,
    this.appBarColor,
    this.useAutoPlatformDetection = true,
    this.onAuthError,
    this.onTokenExtractionError,
    this.authTimeout = const Duration(minutes: 5),
  });

  // Global logout callback for RonelManager to use
  static VoidCallback? _globalLogoutCallback;

  // Global auth URL to check against for session expiration
  static String? _globalAuthUrl;

  // Global tab switching callback for RonelManager to use
  static Function(String)? _globalGoToTabCallback;

  @override
  State<RonelAuth> createState() => _RonelAuthState();
}

class _RonelAuthState extends State<RonelAuth> {
  bool _isAuthenticated = false;
  bool _isLoading = true;
  String? _authToken;
  InAppWebViewController? _authController;
  Timer? _urlMonitoringTimer;

  UIDesign get _uiDesign {
    if (!widget.useAutoPlatformDetection && widget.uiDesign != null) {
      switch (widget.uiDesign!.toLowerCase()) {
        case 'cupertino':
          return UIDesign.cupertino;
        case 'material':
        default:
          return UIDesign.material;
      }
    }

    // Auto-detect based on platform
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return UIDesign.cupertino;
      case TargetPlatform.android:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
      default:
        return UIDesign.material;
    }
  }

  @override
  void initState() {
    super.initState();
    // Set the global logout callback and auth URL
    RonelAuth._globalLogoutCallback = logout;
    RonelAuth._globalAuthUrl = widget.authUrl;
    _checkAuthenticationStatus();
  }

  @override
  void dispose() {
    // Cancel URL monitoring timer
    _urlMonitoringTimer?.cancel();
    _urlMonitoringTimer = null;

    // Clear the global logout callback and auth URL
    RonelAuth._globalLogoutCallback = null;
    RonelAuth._globalAuthUrl = null;
    super.dispose();
  }

  Future<void> _checkAuthenticationStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isAuthenticated = prefs.getBool('isAuthenticated') ?? false;
      final authToken = prefs.getString('authToken');

      debugPrint(
          'Checking auth status: isAuthenticated = $isAuthenticated, hasToken = ${authToken != null}');

      setState(() {
        _isAuthenticated =
            isAuthenticated && authToken != null && authToken.isNotEmpty;
        _authToken = authToken;
        _isLoading = false;
      });

      if (!_isAuthenticated) {
        debugPrint('User not authenticated, initializing auth WebView');
        // No explicit _initializeAuthWebView call here. The build method will render
        // the InAppWebView with the authUrl if not authenticated.
      } else {
        debugPrint('User is authenticated');
      }
    } catch (e) {
      debugPrint('Error checking authentication status: $e');
      widget.onAuthError?.call();
      setState(() {
        _isLoading = false;
        _isAuthenticated = false;
        _authToken = null;
      });
    }
  }

  void _checkForTokenInUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final tokenValue = uri.queryParameters[widget.tokenParamName];
      debugPrint('Checking URL for token: $url');
      debugPrint('Token parameter name: ${widget.tokenParamName}');
      debugPrint('Token extracted from URL: $tokenValue');
      debugPrint('All query parameters: ${uri.queryParameters}');

      if (tokenValue != null && tokenValue.isNotEmpty) {
        debugPrint('Valid token found, handling successful auth');
        _handleSuccessfulAuth(tokenValue);
      }
    } catch (e) {
      debugPrint('Error parsing URL for token: $e');
      widget.onTokenExtractionError?.call();
    }
  }

  Future<void> _injectUrlMonitoringScript(
      InAppWebViewController controller) async {
    // First inject the Ronel hidden CSS
    await controller.evaluateJavascript(source: '''
      (function() {
        // Only inject if not already present
        if (document.getElementById('ronel-hidden-style')) return;
        
        // Create style element immediately at page start
        var ronelStyle = document.createElement('style');
        ronelStyle.id = 'ronel-hidden-style';
        ronelStyle.type = 'text/css';
        
        // CSS to hide elements with ronel_hidden class - make it as strong as possible
        ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
        
        // Insert at the very beginning of head for maximum priority
        var head = document.head || document.getElementsByTagName('head')[0];
        head.insertBefore(ronelStyle, head.firstChild);
      })();
    ''');

    // Then inject the URL monitoring script
    await controller.evaluateJavascript(source: '''
      (function() {
        // Monitor for URL changes that Rails Turbo might cause
        let lastUrl = window.location.href;
        
        function checkUrlChange() {
          const currentUrl = window.location.href;
          if (currentUrl !== lastUrl) {
            console.log('URL changed from', lastUrl, 'to', currentUrl);
            lastUrl = currentUrl;
            
            // Send URL change to Flutter
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('AuthTokenChecker', {
                url: currentUrl,
                timestamp: Date.now()
              });
            }
          }
        }
        
        // Check URL changes every 500ms
        setInterval(checkUrlChange, 500);
        
        // Also listen for various navigation events
        window.addEventListener('popstate', checkUrlChange);
        
        // Listen for Turbo events if they exist
        if (window.Turbo) {
          document.addEventListener('turbo:visit', checkUrlChange);
          document.addEventListener('turbo:load', checkUrlChange);
          document.addEventListener('turbo:render', checkUrlChange);
        }
        
        // Listen for pushstate/replacestate
        const originalPushState = history.pushState;
        const originalReplaceState = history.replaceState;
        
        history.pushState = function() {
          originalPushState.apply(history, arguments);
          setTimeout(checkUrlChange, 100);
        };
        
        history.replaceState = function() {
          originalReplaceState.apply(history, arguments);
          setTimeout(checkUrlChange, 100);
        };
        
        console.log('Auth URL monitoring script injected');
      })();
    ''');
  }

  void _startUrlMonitoring(InAppWebViewController controller) {
    // Cancel any existing timer
    _urlMonitoringTimer?.cancel();

    // Start a timer to periodically check the current URL
    _urlMonitoringTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _isAuthenticated) {
        timer.cancel();
        _urlMonitoringTimer = null;
        return;
      }

      try {
        final url = await controller.getUrl();
        if (url != null) {
          _checkForTokenInUrl(url.toString());
        }
      } catch (e) {
        debugPrint('Error getting current URL: $e');
      }
    });
  }

  Future<void> _handleSuccessfulAuth(String token) async {
    try {
      // Stop URL monitoring immediately
      _urlMonitoringTimer?.cancel();
      _urlMonitoringTimer = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('authToken', token);
      await prefs.setBool('isAuthenticated', true);

      setState(() {
        _isAuthenticated = true;
        _authToken = token;
      });

      debugPrint('Authentication successful, token stored');
    } catch (e) {
      debugPrint('Error storing authentication data: $e');
      widget.onAuthError?.call();
    }
  }

  Future<void> logout() async {
    try {
      debugPrint('Starting logout process...');

      final prefs = await SharedPreferences.getInstance();

      // Clear all authentication-related keys
      await prefs.remove('authToken');
      await prefs.remove('isAuthenticated');

      // Also try to clear the boolean explicitly
      await prefs.setBool('isAuthenticated', false);

      debugPrint('SharedPreferences cleared');

      // Clear the current auth controller if it exists
      if (_authController != null) {
        // _authController.dispose(); // InAppWebViewController typically disposed by widget lifecycle
        _authController = null;
      }

      // Update state to force widget rebuild
      setState(() {
        _isAuthenticated = false;
        _authToken = null;
        _authController = null; // Ensure it's null to trigger new InAppWebView
      });

      debugPrint('State updated: _isAuthenticated = $_isAuthenticated');

      // No explicit _initializeAuthWebView call needed, build method handles it.
      debugPrint('User logged out successfully');
    } catch (e) {
      debugPrint('Error during logout: $e');
    }
  }

  String _appendTokenToUrl(String originalUrl, String token) {
    try {
      final uri = Uri.parse(originalUrl);
      final queryParams = Map<String, String>.from(uri.queryParameters);
      queryParams[widget.authTokenParamName] = token;

      final newUri = uri.replace(queryParameters: queryParams);
      return newUri.toString();
    } catch (e) {
      debugPrint('Error appending token to URL: $e');
      return originalUrl;
    }
  }

  Widget _buildModifiedLoadAfterAuthWidget() {
    if (_authToken == null) return widget.loadAfterAuth;

    // Create a modified version of the loadAfterAuth widget with token-appended URL
    if (widget.loadAfterAuth is Ronel) {
      final ronel = widget.loadAfterAuth as Ronel;
      final modifiedUrl = _appendTokenToUrl(ronel.url, _authToken!);

      return Ronel(
        url: modifiedUrl,
        title: ronel.title,
        appTitle: ronel.appTitle,
        appBarColor: ronel.appBarColor,
        uiDesign: ronel.uiDesign,
        useAutoPlatformDetection: ronel.useAutoPlatformDetection,
        materialTheme: ronel.materialTheme,
        cupertinoTheme: ronel.cupertinoTheme,
      );
    } else if (widget.loadAfterAuth is RonelTabApp) {
      final ronelTabApp = widget.loadAfterAuth as RonelTabApp;

      // For RonelTabApp, we need to modify the URLs in tabs or configUrl
      if (ronelTabApp.tabs != null) {
        final modifiedTabs = ronelTabApp.tabs!.map((tab) {
          final modifiedUrl = _appendTokenToUrl(tab.url, _authToken!);
          return RonelTab(
            url: modifiedUrl,
            title: tab.title,
            icon: tab.icon,
            activeIcon: tab.activeIcon,
          );
        }).toList();

        return RonelTabApp(
          tabs: modifiedTabs,
          appTitle: ronelTabApp.appTitle,
          appBarColor: ronelTabApp.appBarColor,
          uiDesign: ronelTabApp.uiDesign,
          useAutoPlatformDetection: ronelTabApp.useAutoPlatformDetection,
          materialTheme: ronelTabApp.materialTheme,
          cupertinoTheme: ronelTabApp.cupertinoTheme,
        );
      } else if (ronelTabApp.configUrl != null) {
        final modifiedConfigUrl =
            _appendTokenToUrl(ronelTabApp.configUrl!, _authToken!);

        return RonelTabApp(
          configUrl: modifiedConfigUrl,
          appTitle: ronelTabApp.appTitle,
          appBarColor: ronelTabApp.appBarColor,
          uiDesign: ronelTabApp.uiDesign,
          useAutoPlatformDetection: ronelTabApp.useAutoPlatformDetection,
          materialTheme: ronelTabApp.materialTheme,
          cupertinoTheme: ronelTabApp.cupertinoTheme,
        );
      }
    }

    return widget.loadAfterAuth;
  }

  Widget _buildAuthWebView() {
    Widget webView = InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.authUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptCanOpenWindowsAutomatically: true,
        javaScriptEnabled: true,
        useHybridComposition: true,
        allowsLinkPreview: false,
        disableLongPressContextMenuOnLinks: true,
        supportZoom: false,
      ),
      onWebViewCreated: (controller) {
        _authController = controller;

        // Inject CSS immediately when WebView is created
        controller.evaluateJavascript(source: '''
          (function() {
            // Only inject if not already present
            if (document.getElementById('ronel-hidden-style')) return;
            
            // Create style element immediately at WebView creation
            var ronelStyle = document.createElement('style');
            ronelStyle.id = 'ronel-hidden-style';
            ronelStyle.type = 'text/css';
            
            // CSS to hide elements with ronel_hidden class - make it as strong as possible
            ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
            
            // Insert at the very beginning of head for maximum priority
            var head = document.head || document.getElementsByTagName('head')[0];
            if (head) {
              head.insertBefore(ronelStyle, head.firstChild);
            }
          })();
        ''');

        // Add JavaScript handler to monitor URL changes continuously
        controller.addJavaScriptHandler(
            handlerName: 'AuthTokenChecker',
            callback: (args) {
              final tokenData = args[0] as Map<String, dynamic>;
              final currentUrl = tokenData['url'] as String?;
              if (currentUrl != null) {
                debugPrint('Auth URL changed via JS: $currentUrl');
                _checkForTokenInUrl(currentUrl);
              }
            });

        // Start periodic URL monitoring for Rails Turbo compatibility
        _startUrlMonitoring(controller);

        // Set up authentication timeout
        Timer(widget.authTimeout, () {
          if (!_isAuthenticated && mounted) {
            debugPrint('Authentication timeout reached');
            widget.onAuthError?.call();
          }
        });
      },
      onLoadStart: (controller, url) async {
        // Inject CSS immediately when page starts loading
        await controller.evaluateJavascript(source: '''
          (function() {
            // Only inject if not already present
            if (document.getElementById('ronel-hidden-style')) return;
            
            // Create style element immediately at page start
            var ronelStyle = document.createElement('style');
            ronelStyle.id = 'ronel-hidden-style';
            ronelStyle.type = 'text/css';
            
            // CSS to hide elements with ronel_hidden class - make it as strong as possible
            ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
            
            // Insert at the very beginning of head for maximum priority
            var head = document.head || document.getElementsByTagName('head')[0];
            head.insertBefore(ronelStyle, head.firstChild);
          })();
        ''');

        // Check URL immediately when loading starts
        if (url != null) {
          debugPrint('Auth load started: ${url.toString()}');
          _checkForTokenInUrl(url.toString());
        }
      },
      onLoadStop: (controller, url) async {
        // Check URL when loading stops
        if (url != null) {
          debugPrint('Auth load stopped: ${url.toString()}');
          _checkForTokenInUrl(url.toString());
        }

        // Inject JavaScript to monitor URL changes for Rails Turbo, for eg.
        await _injectUrlMonitoringScript(controller);
      },
      onUpdateVisitedHistory: (controller, url, androidIsReload) async {
        // This catches navigation that might not trigger onLoadStop
        if (url != null) {
          debugPrint('Auth history updated: ${url.toString()}');
          _checkForTokenInUrl(url.toString());
        }
      },
      onReceivedError: (controller, request, error) {
        debugPrint('Auth WebView error: ${error.description}');
        widget.onAuthError?.call();
      },
    );

    if (_uiDesign == UIDesign.cupertino) {
      return CupertinoApp(
        home: CupertinoPageScaffold(
          navigationBar: widget.showAppBar
              ? CupertinoNavigationBar(
                  backgroundColor:
                      widget.appBarColor ?? CupertinoColors.systemBackground,
                  middle: Text('${widget.title}'),
                  leading: widget.showCancelButton
                      ? CupertinoNavigationBarBackButton(
                          onPressed: () {
                            // Handle back button - could call onAuthError or just log
                            debugPrint('Authentication cancelled by user');
                            widget.onAuthError?.call();
                          },
                        )
                      : null,
                )
              : null,
          child: SafeArea(child: webView),
        ),
      );
    } else {
      return MaterialApp(
        home: Scaffold(
          appBar: widget.showAppBar
              ? AppBar(
                  backgroundColor: widget.appBarColor,
                  title: Text('${widget.title}'),
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      // Handle back button - could call onAuthError or just log
                      debugPrint('Authentication cancelled by user');
                      widget.onAuthError?.call();
                    },
                  ),
                )
              : null,
          body: webView,
        ),
      );
    }
  }

  Widget _buildLoadingWidget() {
    Widget loading = _uiDesign == UIDesign.cupertino
        ? const Center(child: CupertinoActivityIndicator())
        : const Center(child: CircularProgressIndicator());

    if (_uiDesign == UIDesign.cupertino) {
      return CupertinoApp(
        home: CupertinoPageScaffold(
          navigationBar: const CupertinoNavigationBar(
            middle: Text('Loading'),
          ),
          child: loading,
        ),
      );
    } else {
      return MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Loading')),
          body: loading,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
        'RonelAuth build called: _isLoading = $_isLoading, _isAuthenticated = $_isAuthenticated');

    if (_isLoading) {
      debugPrint('RonelAuth: Showing loading widget');
      return _buildLoadingWidget();
    }

    if (_isAuthenticated) {
      debugPrint('RonelAuth: User authenticated, showing loadAfterAuth widget');
      return _buildModifiedLoadAfterAuthWidget();
    } else {
      debugPrint('RonelAuth: User not authenticated, showing auth WebView');
      return _buildAuthWebView();
    }
  }
}

// Prefetch cache entry
class PrefetchCacheEntry {
  final String url;
  final String html;
  final DateTime cachedAt;
  final Duration maxAge;
  final bool isSecondLevel;

  PrefetchCacheEntry({
    required this.url,
    required this.html,
    required this.cachedAt,
    this.maxAge = const Duration(minutes: 10),
    this.isSecondLevel = false,
  });

  bool get isExpired => DateTime.now().difference(cachedAt) > maxAge;
}

// Prefetch manager for handling link prefetching
class PrefetchManager {
  static final PrefetchManager _instance = PrefetchManager._internal();
  factory PrefetchManager() => _instance;
  PrefetchManager._internal();

  final Map<String, PrefetchCacheEntry> _cache = {};
  final Map<String, Future<void>> _activePrefetches = {};
  Timer? _cleanupTimer;

  void initialize() {
    // Clear all caches on app start
    clearAllCaches();

    // Start periodic cleanup of expired entries
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanupExpiredEntries();
    });
  }

  void clearAllCaches() {
    _cache.clear();
    _activePrefetches.clear();
    debugPrint('Ronel: All caches cleared on app start');
  }

  void _cleanupExpiredEntries() {
    _cache.removeWhere((url, entry) => entry.isExpired);
  }

  Future<void> prefetchUrl(String url, String baseUrl,
      {bool isSecondLevel = false}) async {
    // Don't prefetch if already cached or currently prefetching
    if (_cache.containsKey(url) && !_cache[url]!.isExpired) {
      return;
    }

    if (_activePrefetches.containsKey(url)) {
      return _activePrefetches[url]!;
    }

    // Validate URL is from same origin as base URL
    if (!_isSameOrigin(url, baseUrl)) {
      return;
    }

    final completer = Completer<void>();
    _activePrefetches[url] = completer.future;

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent':
              'RonelApp/1.0 (Flutter InAppWebView)', // Updated User-Agent
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        _cache[url] = PrefetchCacheEntry(
          url: url,
          html: response.body,
          cachedAt: DateTime.now(),
          isSecondLevel: isSecondLevel,
        );
        debugPrint('Prefetched${isSecondLevel ? ' (L2)' : ''}: $url');

        // If this is first-level prefetch, trigger second-level prefetching
        if (!isSecondLevel) {
          _scheduleSecondLevelPrefetch(url, response.body, baseUrl);
        }
      }
    } catch (e) {
      debugPrint('Prefetch failed for $url: $e');
    } finally {
      _activePrefetches.remove(url);
      completer.complete();
    }
  }

  String? getCachedHtml(String url) {
    final entry = _cache[url];
    if (entry != null && !entry.isExpired) {
      return entry.html;
    }
    return null;
  }

  bool _isSameOrigin(String url, String baseUrl) {
    try {
      final uri = Uri.parse(url);
      final baseUri = Uri.parse(baseUrl);
      return uri.host == baseUri.host && uri.port == baseUri.port;
    } catch (e) {
      return false;
    }
  }

  Future<void> scanPageForLinks(String pageUrl, String baseUrl) async {
    try {
      final response = await http.get(
        Uri.parse(pageUrl),
        headers: {
          'User-Agent':
              'RonelApp/1.0 (Flutter InAppWebView)', // Updated User-Agent
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final links = _extractLinksFromHtml(response.body, baseUrl);

        // Prefetch up to 8 links more aggressively for faster navigation
        final linksToPrefetch = links.take(8);

        // Start prefetching immediately with smaller delays
        int delayMultiplier = 0;
        for (final link in linksToPrefetch) {
          Future.delayed(Duration(milliseconds: 50 * delayMultiplier), () {
            prefetchUrl(link, baseUrl);
          });
          delayMultiplier++;
        }
      }
    } catch (e) {
      debugPrint('Failed to scan page for links: $e');
    }
  }

  List<String> _extractLinksFromHtml(String html, String baseUrl) {
    final links = <String>[];
    final baseUri = Uri.parse(baseUrl);

    // Simple regex to find href attributes - using simple pattern
    final hrefRegex = RegExp(r'href="([^"]*)"', caseSensitive: false);
    final hrefRegexSingle = RegExp(r"href='([^']*)'", caseSensitive: false);

    final matches = <RegExpMatch>[];
    matches.addAll(hrefRegex.allMatches(html));
    matches.addAll(hrefRegexSingle.allMatches(html));

    for (final match in matches) {
      final href = match.group(1);
      if (href != null && href.isNotEmpty) {
        try {
          // Convert relative URLs to absolute
          final uri = Uri.parse(href);
          final absoluteUrl =
              uri.hasScheme ? href : baseUri.resolve(href).toString();

          // Only include same-origin links
          if (_isSameOrigin(absoluteUrl, baseUrl)) {
            links.add(absoluteUrl);
          }
        } catch (e) {
          // Skip invalid URLs
        }
      }
    }

    return links.toSet().toList(); // Remove duplicates
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _cache.clear();
    _activePrefetches.clear();
  }

  void _scheduleSecondLevelPrefetch(
      String parentUrl, String html, String baseUrl) {
    // Extract links from the cached HTML
    final links = _extractLinksFromHtml(html, baseUrl);

    // Limit second-level prefetching to 3 links to avoid overwhelming
    final linksToPrefetch = links.take(3);

    // Schedule second-level prefetching with longer delays
    int delayMultiplier = 0;
    for (final link in linksToPrefetch) {
      // Skip if already cached
      if (_cache.containsKey(link) && !_cache[link]!.isExpired) {
        continue;
      }

      // Use longer delays for second-level (500ms between requests)
      Future.delayed(Duration(milliseconds: 500 * delayMultiplier), () {
        prefetchUrl(link, baseUrl, isSecondLevel: true);
      });
      delayMultiplier++;
    }

    debugPrint(
        'Scheduled ${linksToPrefetch.length} second-level prefetches for $parentUrl');
  }

  void triggerSecondLevelPrefetchingForCached(String baseUrl) {
    // Go through all cached first-level entries and trigger second-level prefetching
    for (final entry in _cache.entries) {
      final cacheEntry = entry.value;

      // Only trigger for first-level cached entries that aren't expired
      if (!cacheEntry.isSecondLevel && !cacheEntry.isExpired) {
        debugPrint(
            'Triggering second-level prefetching for cached: ${entry.key}');
        _scheduleSecondLevelPrefetch(entry.key, cacheEntry.html, baseUrl);
      }
    }
  }

  Map<String, dynamic> getCacheStats() {
    int firstLevelCount = 0;
    int secondLevelCount = 0;
    int expiredCount = 0;

    for (final entry in _cache.values) {
      if (entry.isExpired) {
        expiredCount++;
      } else if (entry.isSecondLevel) {
        secondLevelCount++;
      } else {
        firstLevelCount++;
      }
    }

    return {
      'totalCached': _cache.length,
      'firstLevel': firstLevelCount,
      'secondLevel': secondLevelCount,
      'expired': expiredCount,
      'activePrefetches': _activePrefetches.length,
    };
  }

  void logCacheStats() {
    final stats = getCacheStats();
    debugPrint('Prefetch Cache Stats: $stats');
  }
}

// Modal WebView Widget with loading spinner
class _ModalWebViewWidget extends StatefulWidget {
  final String url;
  final String title;
  final UIDesign uiDesign;
  final Color? appBarColor;
  final BuildContext modalContext;
  final RonelManager manager;

  const _ModalWebViewWidget({
    required this.url,
    required this.title,
    required this.uiDesign,
    this.appBarColor,
    required this.modalContext,
    required this.manager,
  });

  @override
  State<_ModalWebViewWidget> createState() => _ModalWebViewWidgetState();
}

class _ModalWebViewWidgetState extends State<_ModalWebViewWidget> {
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    debugPrint('_ModalWebViewWidget created for URL: ${widget.url}');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: widget.uiDesign == UIDesign.cupertino
              ? CupertinoColors.systemBackground
              : Colors.white,
          borderRadius: const BorderRadius.all(Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: widget.appBarColor ??
                    (widget.uiDesign == UIDesign.cupertino
                        ? CupertinoColors.systemBackground
                        : Theme.of(widget.modalContext).colorScheme.inversePrimary),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: widget.uiDesign == UIDesign.cupertino
                          ? CupertinoTheme.of(widget.modalContext)
                              .textTheme
                              .navTitleTextStyle
                          : Theme.of(widget.modalContext).textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.uiDesign == UIDesign.cupertino)
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      child: const Icon(CupertinoIcons.xmark),
                      onPressed: () => Navigator.of(widget.modalContext).pop(),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(widget.modalContext).pop(),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(20)),
                child: Stack(
                  children: [
                    InAppWebView(
                      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                      initialSettings: InAppWebViewSettings(
                        javaScriptCanOpenWindowsAutomatically: true,
                        javaScriptEnabled: true,
                        useHybridComposition: true,
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        iframeAllow: "camera; microphone",
                        iframeAllowFullscreen: true,
                        allowsLinkPreview: false,
                        disableLongPressContextMenuOnLinks: true,
                        supportZoom: false,
                      ),
                      initialUserScripts: UnmodifiableListView<UserScript>([
                        UserScript(
                          source: '''
                            (function() {
                              // Create style element immediately
                              var ronelStyle = document.createElement('style');
                              ronelStyle.id = 'ronel-hidden-style';
                              ronelStyle.type = 'text/css';
                              ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
                              
                              // Function to inject CSS
                              function injectCSS() {
                                var head = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
                                if (head && !document.getElementById('ronel-hidden-style')) {
                                  head.insertBefore(ronelStyle, head.firstChild);
                                }
                              }
                              
                              // Try to inject immediately
                              injectCSS();
                              
                              // Also inject when DOM is ready
                              if (document.readyState === 'loading') {
                                document.addEventListener('DOMContentLoaded', injectCSS);
                              }
                            })();
                          ''',
                          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                        ),
                      ]),
                      onWebViewCreated: (controller) {
                        // This controller is local to the modal WebView
                        widget.manager._injectLinkInterceptorForModal(controller);
                        controller.addJavaScriptHandler(
                            handlerName: 'RonelBridge',
                            callback: (args) {
                              widget.manager._handleModalBridgeMessageWithModalContext(
                                  args[0], widget.modalContext);
                            });
                      },
                      onLoadStop: (controller, url) async {
                        widget.manager._injectLinkInterceptorForModal(controller);
                        if (mounted) {
                          setState(() {
                            isLoading = false;
                          });
                        }
                      },
                      onReceivedError: (controller, request, error) {
                        debugPrint(
                            'Modal WebView Error: ${error.description}');
                        if (mounted) {
                          setState(() {
                            isLoading = false;
                          });
                        }
                      },
                      onProgressChanged: (controller, progress) {
                        if (progress == 100 && mounted) {
                          setState(() {
                            isLoading = false;
                          });
                        }
                      },
                    ),
                    if (isLoading)
                      Container(
                        decoration: BoxDecoration(
                          color: widget.uiDesign == UIDesign.cupertino
                              ? CupertinoColors.systemBackground
                              : Colors.white,
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(20)),
                        ),
                        child: Center(
                          child: widget.uiDesign == UIDesign.cupertino
                              ? const CupertinoActivityIndicator(
                                  radius: 20,
                                )
                              : CircularProgressIndicator(
                                  color: widget.appBarColor ?? Colors.deepPurple,
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Cover WebView Widget with loading spinner
class _CoverWebViewWidget extends StatefulWidget {
  final String url;
  final String title;
  final UIDesign uiDesign;
  final BuildContext modalContext;
  final RonelManager manager;

  const _CoverWebViewWidget({
    required this.url,
    required this.title,
    required this.uiDesign,
    required this.modalContext,
    required this.manager,
  });

  @override
  State<_CoverWebViewWidget> createState() => _CoverWebViewWidgetState();
}

class _CoverWebViewWidgetState extends State<_CoverWebViewWidget> {
  bool isLoading = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.uiDesign == UIDesign.cupertino
          ? CupertinoColors.systemBackground
          : Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            // Close button in top left
            Container(
              padding: const EdgeInsets.all(16),
              alignment: Alignment.centerLeft,
              child: widget.uiDesign == UIDesign.cupertino
                  ? CupertinoButton(
                      padding: EdgeInsets.zero,
                      child: const Icon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 30,
                        color: CupertinoColors.systemGrey,
                      ),
                      onPressed: () => Navigator.of(widget.modalContext).pop(),
                    )
                  : IconButton(
                      icon: const Icon(
                        Icons.close,
                        size: 30,
                      ),
                      onPressed: () => Navigator.of(widget.modalContext).pop(),
                    ),
            ),
            // Full screen WebView
            Expanded(
              child: Stack(
                children: [
                  InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptCanOpenWindowsAutomatically: true,
                      javaScriptEnabled: true,
                      useHybridComposition: true,
                      mediaPlaybackRequiresUserGesture: false,
                      allowsInlineMediaPlayback: true,
                      iframeAllow: "camera; microphone",
                      iframeAllowFullscreen: true,
                      allowsLinkPreview: false,
                      disableLongPressContextMenuOnLinks: true,
                      supportZoom: false,
                    ),
                    initialUserScripts: UnmodifiableListView<UserScript>([
                      UserScript(
                        source: '''
                          (function() {
                            // Create style element immediately
                            var ronelStyle = document.createElement('style');
                            ronelStyle.id = 'ronel-hidden-style';
                            ronelStyle.type = 'text/css';
                            ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
                            
                            // Function to inject CSS
                            function injectCSS() {
                              var head = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
                              if (head && !document.getElementById('ronel-hidden-style')) {
                                head.insertBefore(ronelStyle, head.firstChild);
                              }
                            }
                            
                            // Try to inject immediately
                            injectCSS();
                            
                            // Also inject when DOM is ready
                            if (document.readyState === 'loading') {
                              document.addEventListener('DOMContentLoaded', injectCSS);
                            }
                          })();
                        ''',
                        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      ),
                    ]),
                    onWebViewCreated: (controller) {
                      widget.manager._injectLinkInterceptorForModal(controller);
                      controller.addJavaScriptHandler(
                          handlerName: 'RonelBridge',
                          callback: (args) {
                            widget.manager._handleModalBridgeMessageWithModalContext(
                                args[0], widget.modalContext);
                          });
                    },
                    onLoadStop: (controller, url) async {
                      widget.manager._injectLinkInterceptorForModal(controller);
                      if (mounted) {
                        setState(() {
                          isLoading = false;
                        });
                      }
                    },
                    onReceivedError: (controller, request, error) {
                      debugPrint('Cover WebView Error: ${error.description}');
                      if (mounted) {
                        setState(() {
                          isLoading = false;
                        });
                      }
                    },
                    onProgressChanged: (controller, progress) {
                      if (progress == 100 && mounted) {
                        setState(() {
                          isLoading = false;
                        });
                      }
                    },
                  ),
                  if (isLoading)
                    Container(
                      color: widget.uiDesign == UIDesign.cupertino
                          ? CupertinoColors.systemBackground
                          : Colors.white,
                      child: Center(
                        child: widget.uiDesign == UIDesign.cupertino
                            ? const CupertinoActivityIndicator(
                                radius: 20,
                              )
                            : const CircularProgressIndicator(
                                color: Colors.deepPurple,
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Sheet WebView Widget with loading spinner (for both sheet and bottomSheet)
class _SheetWebViewWidget extends StatefulWidget {
  final String url;
  final String title;
  final UIDesign uiDesign;
  final Color? appBarColor;
  final BuildContext modalContext;
  final RonelManager manager;
  final double initialChildSize;
  final double maxChildSize;
  final double minChildSize;
  final bool isBottomSheet;

  const _SheetWebViewWidget({
    required this.url,
    required this.title,
    required this.uiDesign,
    this.appBarColor,
    required this.modalContext,
    required this.manager,
    this.initialChildSize = 1.0,
    this.maxChildSize = 1.0,
    this.minChildSize = 0.3,
    this.isBottomSheet = false,
  });

  @override
  State<_SheetWebViewWidget> createState() => _SheetWebViewWidgetState();
}

class _SheetWebViewWidgetState extends State<_SheetWebViewWidget> {
  bool isLoading = true;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: widget.initialChildSize,
      maxChildSize: widget.maxChildSize,
      minChildSize: widget.minChildSize,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: widget.uiDesign == UIDesign.cupertino
              ? CupertinoColors.systemBackground
              : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              margin: EdgeInsets.symmetric(vertical: widget.isBottomSheet ? 12 : 8),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptCanOpenWindowsAutomatically: true,
                      javaScriptEnabled: true,
                      useHybridComposition: true,
                      mediaPlaybackRequiresUserGesture: false,
                      allowsInlineMediaPlayback: true,
                      iframeAllow: "camera; microphone",
                      iframeAllowFullscreen: true,
                      allowsLinkPreview: false,
                      disableLongPressContextMenuOnLinks: true,
                      supportZoom: false,
                    ),
                    initialUserScripts: UnmodifiableListView<UserScript>([
                      UserScript(
                        source: '''
                          (function() {
                            // Create style element immediately
                            var ronelStyle = document.createElement('style');
                            ronelStyle.id = 'ronel-hidden-style';
                            ronelStyle.type = 'text/css';
                            ronelStyle.innerHTML = '.ronel_hidden { display: none !important; visibility: hidden !important; opacity: 0 !important; }';
                            
                            // Function to inject CSS
                            function injectCSS() {
                              var head = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
                              if (head && !document.getElementById('ronel-hidden-style')) {
                                head.insertBefore(ronelStyle, head.firstChild);
                              }
                            }
                            
                            // Try to inject immediately
                            injectCSS();
                            
                            // Also inject when DOM is ready
                            if (document.readyState === 'loading') {
                              document.addEventListener('DOMContentLoaded', injectCSS);
                            }
                          })();
                        ''',
                        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      ),
                    ]),
                    onWebViewCreated: (controller) {
                      widget.manager._injectLinkInterceptorForModal(controller);
                      controller.addJavaScriptHandler(
                          handlerName: 'RonelBridge',
                          callback: (args) {
                            widget.manager._handleModalBridgeMessageWithModalContext(
                                args[0], widget.modalContext);
                          });
                    },
                    onLoadStop: (controller, url) async {
                      widget.manager._injectLinkInterceptorForModal(controller);
                      if (mounted) {
                        setState(() {
                          isLoading = false;
                        });
                      }
                    },
                    onReceivedError: (controller, request, error) {
                      debugPrint(
                          '${widget.isBottomSheet ? "BottomSheet" : "Sheet"} WebView Error: ${error.description}');
                      if (mounted) {
                        setState(() {
                          isLoading = false;
                        });
                      }
                    },
                    onProgressChanged: (controller, progress) {
                      if (progress == 100 && mounted) {
                        setState(() {
                          isLoading = false;
                        });
                      }
                    },
                  ),
                  if (isLoading)
                    Container(
                      color: widget.uiDesign == UIDesign.cupertino
                          ? CupertinoColors.systemBackground
                          : Colors.white,
                      child: Center(
                        child: widget.uiDesign == UIDesign.cupertino
                            ? const CupertinoActivityIndicator(
                                radius: 20,
                              )
                            : CircularProgressIndicator(
                                color: widget.appBarColor ?? Colors.deepPurple,
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
