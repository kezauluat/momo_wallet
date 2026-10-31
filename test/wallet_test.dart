import 'package:flutter_test/flutter_test.dart';
import 'package:momo_wallet/main.dart';

void main() {
  test('starts at 10,000 RWF with sample transactions', () {
    final w = Wallet();
    expect(w.balance, 10000);
    expect(w.history.isNotEmpty, true);
  });

  test('send rules', () {
    final w = Wallet();
    expect(w.send('0721234567', '1000'), 'Phone number must start with 078 or 079');
    expect(w.send('0788123456', '50'), 'You must send at least 100 RWF');
    expect(w.send('078812345', '1000'), 'Phone number must be exactly 10 digits');
    expect(w.send('0788123456', '1000000'), 'Insufficient balance');
    expect(w.send('0788123456', '5k'), isNotNull);
    expect(w.send('0788123456', '0'), isNotNull);
    expect(w.send('0788123456', '-200'), isNotNull);
    expect(w.balance, 10000); // nothing moved
    expect(w.send('0788123456', '1000'), isNull);
    expect(w.history.last.description, 'Sent to 0788123456');
    expect(w.balance, 9000);
  });

  test('cash out notes', () {
    expect(Wallet.notesFor(23700), {5000: 4, 2000: 1, 1000: 1, 500: 1, 100: 2});
    final w = Wallet();
    expect(w.checkCashOut('250'), isNotNull);
    expect(w.checkCashOut('23700'), 'Insufficient balance');
    expect(w.cashOut('3000'), isNull);
    expect(w.history.last.description, 'Cash out');
  });

  test('statistics and delete', () {
    final w = Wallet();
    expect(w.totalIn, 3000);
    expect(w.totalOut, 3000);
    expect(w.lowestBalance, 9000);

    w.receive('Salary', '5000'); // 15000
    w.send('0788123456', '2000'); // 13000
    w.cashOut('3000'); // 10000
    expect(w.totalIn, 8000);
    expect(w.totalOut, 8000);
    expect(w.lowestBalance, 9000);

    // Delete the first sample (Airtime OUT 1000): lowest goes up to 10000
    final airtime = w.history.first;
    final pos = w.delete(airtime);
    expect(w.balance, 11000);
    expect(w.lowestBalance, 10000);
    expect(w.undoDelete(pos, airtime), isNull);
    expect(w.balance, 10000);
  });

  test('delete refused when balance would go below 0', () {
    final w = Wallet();
    w.receive('Big gift', '100000');
    final gift = w.history.last;
    w.cashOut('100000');
    expect(w.checkDelete(gift), isNotNull);
  });

  test('edit rules', () {
    final w = Wallet();
    final fromMama = w.history[1]; // IN 3000
    expect(w.checkEdit(fromMama, '', '3000'), 'Description cannot be empty');
    expect(w.checkEdit(fromMama, 'From Mama', 'abc'), isNotNull);
    expect(w.checkEdit(fromMama, 'From Mama', '5000'), isNull);
    // Making a big OUT would take the balance below 0
    final airtime = w.history.first;
    expect(w.checkEdit(airtime, 'Airtime', '20000'), isNotNull);
  });
}
