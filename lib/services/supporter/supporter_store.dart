import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

/// Product ID of the one-time Supporter purchase, the same on the App Store and
/// Google Play.
const String supporterProductId = 'supporter';

/// What a store's purchase history says about the Supporter purchase on the
/// signed-in store account.
enum SupporterOwnership {
  /// A completed purchase that has not been refunded or revoked.
  owned,

  /// Only a purchase that is still waiting for payment (Play's pending payment methods).
  pending,

  /// The store confirmed the account does not own it: refunded or revoked.
  revoked,

  /// The store holds no record either way, so the cached entitlement stands.
  unknown,
}

/// One answer from a store's purchase history.
@immutable
class SupporterHistory {
  const SupporterHistory(this.ownership, {this.unfinished = const []});

  final SupporterOwnership ownership;

  /// Owned Supporter purchases the store still expects the app to complete.
  final List<PurchaseDetails> unfinished;
}

/// The store's billing service is not usable on this device: no store app,
/// no signed-in account, or an unsupported billing version.
class SupporterStoreUnavailable implements Exception {
  const SupporterStoreUnavailable();
}

/// The user dismissed the store's sign-in during Restore Purchases.
class SupporterRestoreCancelled implements Exception {
  const SupporterRestoreCancelled();
}

/// The store calls behind the Supporter purchase.
///
/// in_app_purchase's cross-store [platform] buys and reports transactions, but
/// cannot say whether the account still owns a purchase. Each store answers
/// that, including refunds and revocations, through its own history API.
abstract class SupporterStore {
  SupporterStore(this.platform);

  final InAppPurchasePlatform platform;

  /// Reads the account's Supporter purchase history from the store. Throws
  /// when the store cannot answer, [SupporterStoreUnavailable] when billing
  /// itself is unavailable; a failure never means "not owned".
  Future<SupporterHistory> queryHistory();

  /// The explicit step a user-initiated restore needs before [queryHistory].
  /// Throws [SupporterRestoreCancelled] when the user dismissed it.
  Future<void> syncForRestore();

  /// Whether a transaction on [InAppPurchasePlatform.purchaseStream] reports a
  /// refund or revocation rather than a purchase.
  bool isRevocation(PurchaseDetails purchase);

  /// The Google Play store. The first [InAppPurchase.instance] registers
  /// the Play Billing implementation.
  static SupporterStore forThisDevice() {
    final iap = InAppPurchase.instance;
    return PlaySupporterStore(
      InAppPurchasePlatform.instance,
      queryPastPurchases: iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>().queryPastPurchases,
    );
  }
}

/// Google Play: the history is Play Billing's purchase query, which lists
/// owned and pending one-time purchases and drops refunded or revoked ones.
class PlaySupporterStore extends SupporterStore {
  PlaySupporterStore(super.platform, {required this._queryPastPurchases});

  final Future<QueryPurchaseDetailsResponse> Function() _queryPastPurchases;

  /// Play Billing answers a query on a client that never connected (no Play
  /// Store, no Google account, "billing API version 3 is not supported") with
  /// an empty, error-free list, which would read as a refund. Only a query on
  /// a connected client can confirm the product is gone.
  @override
  Future<SupporterHistory> queryHistory() async {
    if (!await platform.isAvailable()) throw const SupporterStoreUnavailable();
    final response = await _queryPastPurchases();
    if (!await platform.isAvailable()) throw const SupporterStoreUnavailable();
    final error = response.error;
    if (error != null) {
      throw InAppPurchaseException(source: error.source, code: error.code, message: error.message);
    }
    final supporter = response.pastPurchases.where((p) => p.productID == supporterProductId).toList();
    final owned = supporter.where((p) => p.status == PurchaseStatus.purchased).toList();
    if (owned.isNotEmpty) {
      return SupporterHistory(
        SupporterOwnership.owned,
        unfinished: [
          for (final purchase in owned)
            if (purchase.pendingCompletePurchase) purchase,
        ],
      );
    }
    if (supporter.any((p) => p.status == PurchaseStatus.pending)) {
      return const SupporterHistory(SupporterOwnership.pending);
    }
    // A successful query without the product: Play removed it, so it was
    // refunded or revoked. Play reports no other revocation signal to the app.
    return const SupporterHistory(SupporterOwnership.revoked);
  }

  /// Play's purchase query already reads the account's current purchases.
  @override
  Future<void> syncForRestore() async {}

  /// Play never reports a refund on the purchase stream; only [queryHistory]
  /// detects one.
  @override
  bool isRevocation(PurchaseDetails purchase) => false;
}
