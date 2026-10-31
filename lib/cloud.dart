// Everything that talks to Firestore. Each user's data lives under
// users/{their id}/transactions, exactly where the rules allow.

import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'main.dart';

/// The signed-in user's transactions: users/{uid}/transactions
CollectionReference<Map<String, dynamic>> myTransactions() {
  final uid = FirebaseAuth.instance.currentUser!.uid;
  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('transactions');
}

/// Sample data, written once when a new account is created.
/// A batch writes them all at once: all of them, or none.
Future<void> addSampleTransactions() async {
  final batch = FirebaseFirestore.instance.batch();
  for (final t in Wallet.sampleTransactions()) {
    batch.set(myTransactions().doc(), {
      ...t.toMap(),
      // The samples keep their own times (3, 2 and 1 days ago).
      'createdAt': Timestamp.fromDate(t.time),
    });
  }
  await batch.commit();
}

/// Saves the transaction the wallet just accepted (the last one) as a new
/// document. Returns false, and shows a message, if it could not be saved.
Future<bool> saveNew(BuildContext context, Wallet wallet) async {
  final messenger = ScaffoldMessenger.of(context);
  final t = wallet.history.last;
  try {
    await myTransactions().add({
      ...t.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return true;
  } catch (e) {
    wallet.history.removeLast(); // it was not saved, so it did not happen
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Could not save. Check your internet.')),
      );
    return false;
  }
}

/// Undo after a delete: write the same data back with the same id.
Future<void> restoreTransaction(Transaction t) {
  return myTransactions().doc(t.id).set({
    ...t.toMap(),
    'createdAt': Timestamp.fromDate(t.time),
  });
}
