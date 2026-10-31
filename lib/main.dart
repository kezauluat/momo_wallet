import 'dart:async';
import 'dart:convert';

// Firestore has its own class called Transaction: hide it, we use ours.
import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'auth_gate.dart';
import 'cloud.dart';
import 'firebase_options.dart';

// ===================== main.dart =====================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android reads android/app/google-services.json by itself.
  // Chrome (web) needs the settings from firebase_options.dart.
  await Firebase.initializeApp(options: kIsWeb ? webOptions : null);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Amafaranga',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF00796B),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

// ===================== format.dart =====================
/// 23700 -> "23,700 RWF"
String money(int amount) {
  final digits = amount.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}$buffer RWF';
}

/// "28 Oct, 14:05"
String shortDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.day} ${months[d.month - 1]}, ${two(d.hour)}:${two(d.minute)}';
}

// ===================== models/transaction.dart =====================
/// One movement of money in the wallet.
class Transaction {
  Transaction({
    this.id = '',
    required this.description,
    required this.amount,
    required this.isIn,
    required this.time,
  });

  final String id; // the Firestore document id ('' before it is saved)
  final String description;
  final int amount; // always positive
  final bool isIn; // true = money came in, false = money went out
  final DateTime time;

  /// +amount for IN, -amount for OUT. Makes adding up the balance easy.
  int get signedAmount => isIn ? amount : -amount;

  /// The facts the user typed or chose. The time is added when saving.
  Map<String, dynamic> toMap() => {
    'description': description,
    'amount': amount,
    'isIn': isIn,
  };

  /// Builds a transaction from a Firestore document.
  factory Transaction.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Transaction(
      id: doc.id,
      description: data['description'] as String,
      amount: (data['amount'] as num).toInt(),
      isIn: data['isIn'] as bool,
      // Just after adding, the server has not written the time yet: use now.
      time: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

// ===================== models/wallet.dart =====================

/// The brain of the app: the data and every rule. No widgets here.
class Wallet {
  /// A wallet with the sample transactions (used by the tests).
  Wallet() {
    history.addAll(sampleTransactions());
  }

  /// A wallet built from the transactions that came from Firestore.
  Wallet.from(List<Transaction> transactions) {
    history.addAll(transactions);
  }

  static const int openingBalance = 10000;
  static const int minimumSend = 100;
  static const List<int> agentNotes = [5000, 2000, 1000, 500, 100];

  /// Every transaction, OLDEST first (the order they happened).
  final List<Transaction> history = [];

  /// The sample data a new account starts with.
  static List<Transaction> sampleTransactions() {
    final now = DateTime.now();
    return [
      Transaction(
        description: 'Airtime',
        amount: 1000,
        isIn: false,
        time: now.subtract(const Duration(days: 3, hours: 2)),
      ),
      Transaction(
        description: 'From Mama',
        amount: 3000,
        isIn: true,
        time: now.subtract(const Duration(days: 2, hours: 5)),
      ),
      Transaction(
        description: 'Sent to 0788123456',
        amount: 2000,
        isIn: false,
        time: now.subtract(const Duration(days: 1, hours: 1)),
      ),
    ];
  }

  // ---------------------------------------------------------------- numbers

  int get balance {
    var total = openingBalance;
    for (final t in history) {
      total += t.signedAmount;
    }
    return total;
  }

  int get totalIn {
    var total = 0;
    for (final t in history) {
      if (t.isIn) total += t.amount;
    }
    return total;
  }

  int get totalOut {
    var total = 0;
    for (final t in history) {
      if (!t.isIn) total += t.amount;
    }
    return total;
  }

  int get lowestBalance => lowestRunningBalance(history);

  /// Replays a history from the opening balance and returns the lowest
  /// balance reached at any point. Starts at the opening balance, not 0.
  static int lowestRunningBalance(List<Transaction> list) {
    var running = openingBalance;
    var lowest = openingBalance;
    for (final t in list) {
      running += t.signedAmount;
      if (running < lowest) lowest = running;
    }
    return lowest;
  }

  /// Newest first, filtered by 'All', 'IN' or 'OUT'. The real list is never changed.
  List<Transaction> shown(String filter) {
    return history.reversed
        .where((t) => filter == 'All' || (filter == 'IN') == t.isIn)
        .toList();
  }

  // ---------------------------------------------------------------- checks
  // Each check returns an error message, or null when everything is fine.

  static String? checkAmount(String text) {
    final amount = int.tryParse(text.trim());
    if (amount == null) return 'Amount must be a whole number, like 5000';
    if (amount <= 0) return 'Amount must be above 0';
    return null;
  }

  static String? checkPhone(String text) {
    final phone = text.trim();
    if (!RegExp(r'^\d{10}$').hasMatch(phone)) {
      return 'Phone number must be exactly 10 digits';
    }
    if (!phone.startsWith('078') && !phone.startsWith('079')) {
      return 'Phone number must start with 078 or 079';
    }
    return null;
  }

  String? checkReceive(String description, String amountText) {
    if (description.trim().isEmpty) return 'Description cannot be empty';
    return checkAmount(amountText);
  }

  String? checkSend(String phoneText, String amountText) {
    final phoneError = checkPhone(phoneText);
    if (phoneError != null) return phoneError;
    final amountError = checkAmount(amountText);
    if (amountError != null) return amountError;
    final amount = int.parse(amountText.trim());
    if (amount < minimumSend) return 'You must send at least $minimumSend RWF';
    if (amount > balance) return 'Insufficient balance';
    return null;
  }

  String? checkCashOut(String amountText) {
    final amountError = checkAmount(amountText);
    if (amountError != null) return amountError;
    final amount = int.parse(amountText.trim());
    if (amount % 100 != 0) {
      return 'Amount must be a multiple of 100 (the smallest note)';
    }
    if (amount > balance) return 'Insufficient balance';
    return null;
  }

  /// The notes the agent hands over, biggest first. 23700 -> {5000:4, 2000:1, 1000:1, 500:1, 100:2}
  static Map<int, int> notesFor(int amount) {
    final result = <int, int>{};
    var left = amount;
    for (final note in agentNotes) {
      final count = left ~/ note;
      if (count > 0) {
        result[note] = count;
        left -= count * note;
      }
    }
    return result;
  }

  // ---------------------------------------------------------------- actions
  // Every action checks FIRST. Money only moves when the check passed.

  String? receive(String description, String amountText) {
    final error = checkReceive(description, amountText);
    if (error != null) return error;
    history.add(Transaction(
      description: description.trim(),
      amount: int.parse(amountText.trim()),
      isIn: true,
      time: DateTime.now(),
    ));
    return null;
  }

  String? send(String phoneText, String amountText) {
    final error = checkSend(phoneText, amountText);
    if (error != null) return error;
    history.add(Transaction(
      description: 'Sent to ${phoneText.trim()}',
      amount: int.parse(amountText.trim()),
      isIn: false,
      time: DateTime.now(),
    ));
    return null;
  }

  String? cashOut(String amountText) {
    final error = checkCashOut(amountText);
    if (error != null) return error;
    history.add(Transaction(
      description: 'Cash out',
      amount: int.parse(amountText.trim()),
      isIn: false,
      time: DateTime.now(),
    ));
    return null;
  }

  // ---------------------------------------------------------------- delete & undo

  /// True when [a] and [b] are the same transaction (same Firestore id).
  static bool _same(Transaction a, Transaction b) =>
      identical(a, b) || (a.id.isNotEmpty && a.id == b.id);

  String? checkDelete(Transaction t) {
    final without = history.where((x) => !_same(x, t)).toList();
    if (lowestRunningBalance(without) < 0) {
      return "Can't delete: the balance would go below 0 in the history";
    }
    return null;
  }

  /// Undo after a delete: is it safe to put [t] back at its own time?
  String? checkRestore(Transaction t) {
    final withIt = [...history, t]..sort((a, b) => a.time.compareTo(b.time));
    if (lowestRunningBalance(withIt) < 0) {
      return "Can't undo: the balance would go below 0";
    }
    return null;
  }

  /// Edit: checks the new description and amount, and that the balance
  /// never goes below 0 anywhere in the history after the change.
  String? checkEdit(Transaction t, String description, String amountText) {
    if (description.trim().isEmpty) return 'Description cannot be empty';
    final amountError = checkAmount(amountText);
    if (amountError != null) return amountError;
    final changed = Transaction(
      id: t.id,
      description: description.trim(),
      amount: int.parse(amountText.trim()),
      isIn: t.isIn,
      time: t.time,
    );
    final list = [for (final x in history) _same(x, t) ? changed : x];
    if (lowestRunningBalance(list) < 0) {
      return "Can't save: the balance would go below 0 in the history";
    }
    return null;
  }

  /// Removes the transaction and returns where it was, for Undo.
  int delete(Transaction t) {
    final position = history.indexWhere((x) => _same(x, t));
    history.removeAt(position);
    return position;
  }

  String? undoDelete(int position, Transaction t) {
    final place = position.clamp(0, history.length);
    final withIt = List.of(history)..insert(place, t);
    if (lowestRunningBalance(withIt) < 0) {
      return "Can't undo: the balance would go below 0";
    }
    history.insert(place, t);
    return null;
  }
}

// ===================== screens/wallet_screen.dart =====================


class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  String filter = 'All';

  /// The live list from Firestore, oldest first. Made once, so changing the
  /// filter does not reconnect.
  final _stream = myTransactions().orderBy('createdAt').snapshots();

  /// The wallet built from the latest data that arrived.
  Wallet _wallet = Wallet.from([]);

  void showMessage(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens a screen. When it comes back with a message, show it.
  /// No setState for the data: Firestore sends the new list by itself.
  void openScreen(Widget screen) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => screen),
    ).then((result) {
      if (result is String) showMessage(result);
    });
  }

  void openTransaction(Transaction t) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => TransactionScreen(transaction: t)),
    ).then((result) {
      if (result == 'delete') deleteTransaction(t);
      if (result == 'edit') {
        openScreen(EditTransactionScreen(wallet: _wallet, transaction: t));
      }
    });
  }

  /// Hold (or the Delete button): Are you sure? Then delete it in Firestore,
  /// with Undo that writes the same data back.
  Future<void> deleteTransaction(Transaction t) async {
    final error = _wallet.checkDelete(t);
    if (error != null) {
      showMessage(error);
      return;
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this transaction?'),
        content: Text('${t.description}  ${t.isIn ? '+' : '-'}${money(t.amount)}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true) return;

    try {
      await myTransactions().doc(t.id).delete();
    } catch (e) {
      if (mounted) showMessage('Could not delete. Check your internet.');
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${t.description} deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            final undoError = _wallet.checkRestore(t);
            if (undoError != null) {
              showMessage(undoError);
              return;
            }
            restoreTransaction(t); // doc(id).set(...) with the same data
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        // Error state: for example, the rules refused.
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Amafaranga'), actions: [logoutButton()]),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load your transactions.\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        // Loading state: nothing has arrived yet.
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        // Data: every document becomes a Transaction; balance and totals
        // are computed from them every time.
        final txns = snapshot.data!.docs.map(Transaction.fromDoc).toList();
        _wallet = Wallet.from(txns);
        return buildWallet(context, _wallet);
      },
    );
  }

  Widget logoutButton() {
    return IconButton(
      icon: const Icon(Icons.logout),
      tooltip: 'Log out',
      onPressed: () => FirebaseAuth.instance.signOut(),
    );
  }

  Widget buildWallet(BuildContext context, Wallet wallet) {
    final shown = wallet.shown(filter);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Amafaranga'),
        centerTitle: true,
        actions: [
          logoutButton(),
          IconButton(
            tooltip: 'Live exchange rates',
            icon: const Icon(Icons.currency_exchange),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => RatesScreen(balance: wallet.balance)),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Balance card
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00796B), Color(0xFF26A69A)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.account_balance_wallet, color: Colors.white70),
                      SizedBox(width: 8),
                      Text('Balance', style: TextStyle(color: Colors.white70, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    money(wallet.balance),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Statistics
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                StatBox(label: 'Total IN', value: money(wallet.totalIn), color: Colors.green.shade700),
                const SizedBox(width: 8),
                StatBox(label: 'Total OUT', value: money(wallet.totalOut), color: Colors.red.shade700),
                const SizedBox(width: 8),
                StatBox(label: 'Lowest', value: money(wallet.lowestBalance), color: scheme.primary),
              ],
            ),
          ),

          // Actions
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                ActionButton(
                  icon: Icons.south_west,
                  label: 'Receive',
                  onTap: () => openScreen(ReceiveScreen(wallet: wallet)),
                ),
                ActionButton(
                  icon: Icons.send,
                  label: 'Send',
                  onTap: () => openScreen(SendScreen(wallet: wallet)),
                ),
                ActionButton(
                  icon: Icons.payments,
                  label: 'Cash out',
                  onTap: () => openScreen(CashOutScreen(wallet: wallet)),
                ),
              ],
            ),
          ),

          // Filter
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                for (final option in ['All', 'IN', 'OUT'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(option),
                      selected: filter == option,
                      onSelected: (_) {
                        setState(() {
                          filter = option;
                        });
                      },
                    ),
                  ),
                const Spacer(),
                Text('Hold to delete', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              ],
            ),
          ),

          // Transactions, newest first
          Expanded(
            child: shown.isEmpty
                ? Center(
              // Empty state: a friendly message, not a blank screen.
              child: Text(
                filter == 'All'
                    ? 'No transactions yet.\nTap Receive to add your first one.'
                    : 'No $filter transactions',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
              ),
            )
                : ListView.builder(
              itemCount: shown.length,
              itemBuilder: (context, index) {
                final t = shown[index];
                final color = t.isIn ? Colors.green.shade700 : Colors.red.shade700;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: t.isIn ? Colors.green.shade50 : Colors.red.shade50,
                    child: Icon(t.isIn ? Icons.south_west : Icons.north_east, color: color),
                  ),
                  title: Text(t.description),
                  subtitle: Text(shortDate(t.time)),
                  trailing: Text(
                    '${t.isIn ? '+' : '-'}${money(t.amount)}',
                    style: TextStyle(color: color, fontWeight: FontWeight.bold),
                  ),
                  onTap: () => openTransaction(t),
                  onLongPress: () => deleteTransaction(t),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class StatBox extends StatelessWidget {
  const StatBox({super.key, required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
            const SizedBox(height: 4),
            FittedBox(
              child: Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}

class ActionButton extends StatelessWidget {
  const ActionButton({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FilledButton.tonal(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(height: 4),
              Text(label, maxLines: 1),
            ],
          ),
        ),
      ),
    );
  }
}

// ===================== screens/receive_screen.dart =====================


class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key, required this.wallet});

  final Wallet wallet;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final descriptionController = TextEditingController();
  final amountController = TextEditingController();

  @override
  void dispose() {
    descriptionController.dispose();
    amountController.dispose();
    super.dispose();
  }

  bool busy = false;

  Future<void> receive() async {
    final error = widget.wallet.receive(descriptionController.text, amountController.text);
    if (error != null) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    setState(() => busy = true);
    final saved = await saveNew(context, widget.wallet);
    if (!mounted) return;
    setState(() => busy = false);
    if (!saved) return;
    final amount = int.parse(amountController.text.trim());
    Navigator.pop(context, 'Received ${money(amount)}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive money')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: descriptionController,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'From Mama',
              prefixIcon: Icon(Icons.notes),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Amount',
              suffixText: 'RWF',
              prefixIcon: Icon(Icons.money),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: busy ? null : receive,
            icon: const Icon(Icons.south_west),
            label: const Text('Receive'),
          ),
        ],
      ),
    );
  }
}

// ===================== screens/send_screen.dart =====================


class SendScreen extends StatefulWidget {
  const SendScreen({super.key, required this.wallet});

  final Wallet wallet;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final phoneController = TextEditingController();
  final amountController = TextEditingController();

  @override
  void dispose() {
    phoneController.dispose();
    amountController.dispose();
    super.dispose();
  }

  bool busy = false;

  Future<void> send() async {
    final error = widget.wallet.send(phoneController.text, amountController.text);
    if (error != null) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    setState(() => busy = true);
    final saved = await saveNew(context, widget.wallet);
    if (!mounted) return;
    setState(() => busy = false);
    if (!saved) return;
    final amount = int.parse(amountController.text.trim());
    Navigator.pop(context, 'Sent ${money(amount)} to ${phoneController.text.trim()}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send money')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Balance: ${money(widget.wallet.balance)}', style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 16),
          TextField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '0788123456',
              prefixIcon: Icon(Icons.phone_android),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Amount (at least 100)',
              suffixText: 'RWF',
              prefixIcon: Icon(Icons.money),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: busy ? null : send,
            icon: const Icon(Icons.send),
            label: const Text('Send'),
          ),
        ],
      ),
    );
  }
}

// ===================== screens/cash_out_screen.dart =====================


class CashOutScreen extends StatefulWidget {
  const CashOutScreen({super.key, required this.wallet});

  final Wallet wallet;

  @override
  State<CashOutScreen> createState() => _CashOutScreenState();
}

class _CashOutScreenState extends State<CashOutScreen> {
  final amountController = TextEditingController();
  Map<int, int>? notes; // null until the user taps "Show notes"

  @override
  void dispose() {
    amountController.dispose();
    super.dispose();
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void showNotes() {
    final error = widget.wallet.checkCashOut(amountController.text);
    if (error != null) {
      showMessage(error);
      return;
    }
    setState(() {
      notes = Wallet.notesFor(int.parse(amountController.text.trim()));
    });
  }

  bool busy = false;

  Future<void> confirm() async {
    final error = widget.wallet.cashOut(amountController.text);
    if (error != null) {
      showMessage(error);
      return;
    }
    setState(() => busy = true);
    final saved = await saveNew(context, widget.wallet);
    if (!mounted) return;
    setState(() => busy = false);
    if (!saved) return;
    final amount = int.parse(amountController.text.trim());
    Navigator.pop(context, 'Cashed out ${money(amount)}');
  }

  @override
  Widget build(BuildContext context) {
    final currentNotes = notes;

    return Scaffold(
      appBar: AppBar(title: const Text('Cash out')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Balance: ${money(widget.wallet.balance)}', style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 16),
          TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Amount (multiple of 100)',
              suffixText: 'RWF',
              prefixIcon: Icon(Icons.money),
              border: OutlineInputBorder(),
            ),
            // Typing a new amount hides the old notes, so Confirm always matches what you see.
            onChanged: (_) {
              if (notes != null) {
                setState(() {
                  notes = null;
                });
              }
            },
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: showNotes,
            icon: const Icon(Icons.visibility),
            label: const Text('Show notes'),
          ),
          if (currentNotes != null) ...[
            const SizedBox(height: 24),
            const Text(
              'The agent will hand you:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final entry in currentNotes.entries)
              Card(
                child: ListTile(
                  leading: Icon(Icons.payments, color: Colors.green.shade700),
                  title: Text(money(entry.key)),
                  trailing: Text(
                    '× ${entry.value}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : confirm,
              icon: const Icon(Icons.check),
              label: const Text('Confirm'),
            ),
          ],
        ],
      ),
    );
  }
}

// ===================== screens/transaction_screen.dart =====================


class TransactionScreen extends StatelessWidget {
  const TransactionScreen({super.key, required this.transaction});

  final Transaction transaction;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final color = t.isIn ? Colors.green.shade700 : Colors.red.shade700;

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: CircleAvatar(
              radius: 36,
              backgroundColor: t.isIn ? Colors.green.shade50 : Colors.red.shade50,
              child: Icon(t.isIn ? Icons.south_west : Icons.north_east, color: color, size: 36),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              '${t.isIn ? '+' : '-'}${money(t.amount)}',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color),
            ),
          ),
          const SizedBox(height: 24),
          ListTile(leading: const Icon(Icons.notes), title: const Text('Description'), subtitle: Text(t.description)),
          ListTile(leading: const Icon(Icons.swap_vert), title: const Text('Type'), subtitle: Text(t.isIn ? 'IN' : 'OUT')),
          ListTile(leading: const Icon(Icons.schedule), title: const Text('Date'), subtitle: Text(shortDate(t.time))),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'edit'),
            icon: const Icon(Icons.edit),
            label: const Text('Edit'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, 'delete'),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade700),
          ),
        ],
      ),
    );
  }
}


// ===================== screens/edit_transaction_screen.dart =====================

/// Step 5: the same kind of form, with the transaction already in it.
/// Saving uses update on that document.
class EditTransactionScreen extends StatefulWidget {
  const EditTransactionScreen({super.key, required this.wallet, required this.transaction});

  final Wallet wallet;
  final Transaction transaction;

  @override
  State<EditTransactionScreen> createState() => _EditTransactionScreenState();
}

class _EditTransactionScreenState extends State<EditTransactionScreen> {
  late final descriptionController = TextEditingController(text: widget.transaction.description);
  late final amountController = TextEditingController(text: '${widget.transaction.amount}');
  bool busy = false;

  @override
  void dispose() {
    descriptionController.dispose();
    amountController.dispose();
    super.dispose();
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> save() async {
    final t = widget.transaction;
    final error = widget.wallet.checkEdit(t, descriptionController.text, amountController.text);
    if (error != null) {
      showMessage(error);
      return;
    }
    setState(() => busy = true);
    try {
      await myTransactions().doc(t.id).update({
        'description': descriptionController.text.trim(),
        'amount': int.parse(amountController.text.trim()),
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => busy = false);
      showMessage('Could not save. Check your internet.');
      return;
    }
    if (!mounted) return;
    Navigator.pop(context, 'Transaction updated');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.transaction;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit transaction')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(t.isIn ? 'Money IN' : 'Money OUT', style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 16),
          TextField(
            controller: descriptionController,
            decoration: const InputDecoration(
              labelText: 'Description',
              prefixIcon: Icon(Icons.notes),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Amount',
              suffixText: 'RWF',
              prefixIcon: Icon(Icons.money),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: busy ? null : save,
            icon: const Icon(Icons.save),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

// ===================== screens/rates_screen.dart =====================

/// One currency and how many RWF one unit of it costs.
class Rate {
  const Rate({required this.code, required this.name, required this.rwf});

  final String code;
  final String name;
  final double rwf;
}

/// What the API gives back: the rates and when they were last updated.
class RatesResult {
  const RatesResult({required this.rates, required this.updated});

  final List<Rate> rates;
  final String updated;
}

/// Gets live exchange rates from open.er-api.com (free, no key).
/// Stops after 10 seconds, so the app never spins forever without internet.
Future<RatesResult> fetchRates() async {
  final response = await http
      .get(Uri.parse('https://open.er-api.com/v6/latest/USD'))
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) {
    throw Exception('Server error ${response.statusCode}');
  }
  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final rates = data['rates'] as Map<String, dynamic>;
  final rwfPerUsd = (rates['RWF'] as num).toDouble();

  const currencies = {
    'USD': 'US Dollar',
    'EUR': 'Euro',
    'GBP': 'British Pound',
    'KES': 'Kenyan Shilling',
    'UGX': 'Ugandan Shilling',
    'TZS': 'Tanzanian Shilling',
  };

  final list = <Rate>[];
  for (final entry in currencies.entries) {
    final perUsd = (rates[entry.key] as num).toDouble();
    list.add(Rate(code: entry.key, name: entry.value, rwf: rwfPerUsd / perUsd));
  }
  return RatesResult(rates: list, updated: data['time_last_update_utc'] as String);
}

/// 1385.4 -> "1,385 RWF"   0.37 -> "0.37 RWF"
String rwfRate(double value) {
  return value >= 10 ? money(value.round()) : '${value.toStringAsFixed(2)} RWF';
}

class RatesScreen extends StatefulWidget {
  const RatesScreen({super.key, required this.balance});

  final int balance;

  @override
  State<RatesScreen> createState() => _RatesScreenState();
}

class _RatesScreenState extends State<RatesScreen> {
  bool loading = true;
  String? error;
  RatesResult? result;

  @override
  void initState() {
    super.initState();
    loadRates();
  }

  Future<void> loadRates() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final rates = await fetchRates();
      if (!mounted) return;
      setState(() {
        result = rates;
        loading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        error = 'The server took too long to answer.\nCheck your internet and try again.';
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        error = 'No internet connection.\nTurn off Airplane mode or connect to Wi-Fi, then try again.';
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live exchange rates'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: loading ? null : loadRates,
          ),
        ],
      ),
      body: buildBody(),
    );
  }

  Widget buildBody() {
    if (loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Getting live rates...'),
          ],
        ),
      );
    }

    final message = error;
    if (message != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off, size: 64, color: Colors.red.shade400),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: loadRates,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final data = result!;
    final usd = data.rates.first.rwf;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF00796B), Color(0xFF26A69A)]),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your balance: ${money(widget.balance)}',
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 6),
              Text(
                'about ${(widget.balance / usd).toStringAsFixed(2)} USD',
                style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        for (final rate in data.rates)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                child: Text(rate.code, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              title: Text('1 ${rate.code} = ${rwfRate(rate.rwf)}'),
              subtitle: Text(rate.name),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Live from open.er-api.com\nUpdated: ${data.updated}',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
      ],
    );
  }
}