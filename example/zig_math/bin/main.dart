import 'package:zig_math/zig_math.dart';

void main() {
  print('Zig Math Library Demo');
  print('  add(3, 4)         = ${add(3, 4)}');
  print('  subtract(10, 3)   = ${subtract(10, 3)}');
  print('  multiply(2.5, 4)  = ${multiply(2.5, 4.0)}');
  print('  divide(10, 3)     = ${divide(10.0, 3.0).toStringAsFixed(4)}');
  print('  factorial(10)     = ${factorial(10)}');
  print('  fibonacci(20)     = ${fibonacci(20)}');
  print('  gcd(48, 18)       = ${gcd(48, 18)}');
  print('  power(2, 10)      = ${power(2.0, 10).toInt()}');
  print('  sqrt(144)         = ${sqrt(144.0).toInt()}');
  print('  absInt(-42)       = ${absInt(-42)}');
  print('  absFloat(-3.14)   = ${absFloat(-3.14)}');
  print('  clamp(15, 0, 10)  = ${clamp(15.0, 0.0, 10.0).toInt()}');
}
