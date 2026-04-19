import 'dart:ffi';

@Native<Int64 Function(Int64, Int64)>()
external int add(int a, int b);

@Native<Int64 Function(Int64, Int64)>()
external int subtract(int a, int b);

@Native<Double Function(Double, Double)>()
external double multiply(double a, double b);

@Native<Double Function(Double, Double)>()
external double divide(double a, double b);

@Native<Uint64 Function(Uint32)>()
external int factorial(int n);

@Native<Uint64 Function(Uint32)>()
external int fibonacci(int n);

@Native<Uint64 Function(Uint64, Uint64)>()
external int gcd(int a, int b);

@Native<Double Function(Double, Int64)>()
external double power(double base, int exp);

@Native<Double Function(Double)>(symbol: 'sqrt_')
external double sqrt(double x);

@Native<Int64 Function(Int64)>(symbol: 'abs_int')
external int absInt(int x);

@Native<Double Function(Double)>(symbol: 'abs_float')
external double absFloat(double x);

@Native<Double Function(Double, Double, Double)>()
external double clamp(double value, double min, double max);
