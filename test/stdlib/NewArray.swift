//===--- Array.swift ------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2015 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
// RUN: %target-run-simple-swift | FileCheck %s

var xCount = 0
var xSerial = 0

// Instead of testing with Int elements, we use this wrapper class
// that can help us track allocations and find issues with object
// lifetime inside Array implementations.
class X : ReplPrintable, ForwardIndex {
  init(value: Int) {
    ++xCount
    serial = ++xSerial
    self.value = value
  }
  
  deinit {
    assert(serial > 0, "double destruction!")
    --xCount
    serial = -serial
  }

  func replPrint() {
    assert(serial > 0, "dead X!")
    value.replPrint()
  }

  func succ() -> X {
    return X(self.value.succ())
  }
  
  var value: Int
  var serial: Int
}

func == (x: X, y: X) -> Bool {
  return x.value == y.value
}

extension Int {
  @conversion
  func __conversion() -> X {
    return X(self)
  }
}

//===----------------------------------------------------------------------===//

func printSequence<
  T: Sequence
  where T.GeneratorType.Element : ReplPrintable
>(x: T) {
  print("[")
  var prefix = ""
  for a in x {
    print(prefix)
    a.replPrint()
    prefix = ", "
  }
  println("]")
}

func bufferID<T : ArrayType>(x: T) -> Int {
  return reinterpretCast(x.buffer.elementStorage) as Int
}

func checkReallocation<T : ArrayType>(
  x: T, lastBuffer: Int, reallocationExpected: Bool
) -> Int {
  let currentBuffer = bufferID(x)
  if (currentBuffer != lastBuffer) != reallocationExpected {
    let message = reallocationExpected ? "lack of" : ""
    println("unexpected \(message) reallocation")
  }
  return currentBuffer
}

func checkEqual<
    S1 : Sequence, S2 : Sequence
  where 
    S1.GeneratorType.Element == S2.GeneratorType.Element,
    S1.GeneratorType.Element : Equatable
>(a1: S1, a2: S2, expected: Bool) {
  if equal(a1, a2) != expected {
    let un = expected ? "un" : ""
    println("unexpectedly \(un)equal sequences!")
  }
}

func test<
  T: ArrayType
where T.GeneratorType.Element == T.Buffer.Element,
          T.Buffer.Element == T.Element,
          T.Element == X,
          T.IndexType == Int
>(_: T.Type, label: String) {
  print("test: \(label)...")

  let rdar16443423 = xCount
  var x: T = [1, 2, 3, 4, 5]
  xCount = rdar16443423
  
  checkEqual(x, 1..5, true)

  x.reserve(x.count + 2)
  checkEqual(x, 1..5, true)
  
  let bufferId0 = bufferID(x)

  // Append a range of integers
  x += 0...2
  let bufferId1 = checkReallocation(x, bufferId0, false)
  
  for i in x.count...(x.capacity + 1) {
    let bufferId1a = checkReallocation(x, bufferId1, false)
    x += 13
  }
  let bufferId2 = checkReallocation(x, bufferId1, true)

  let y = x
  x[x.endIndex.pred()] = 17
  let bufferId3 = checkReallocation(x, bufferId2, true)
  checkEqual(x, y, false)
  println("done.")
}

println("testing...")
// CHECK: testing...

test(NativeArray<X>.self, "NativeArray")
// CHECK-NEXT: test: NativeArray...done

test(NewArray<X>.self, "Array")
// CHECK-NEXT: test: Array...done

test(Slice<X>.self, "Slice")
// CHECK-NEXT: test: Slice...done

func testAsArray() {
  println("== AsArray ==")
  let rdar16443423 = xCount
  var w: NativeArray<X> = [4, 2, 1]
  xCount = rdar16443423
  // CHECK: == AsArray == 
  
  let x: NativeArray<X> = asArray(w)
  println(bufferID(w) == bufferID(x))
  // CHECK-NEXT: true
  
  let y: NewArray<X> = asArray(x)
  println(bufferID(x) == bufferID(y))
  // CHECK-NEXT: true
  
  let z: Slice<X> = asArray(y)
  println(bufferID(y) == bufferID(z))
  // CHECK-NEXT: true

  w = asArray(z)
  println(bufferID(w) == bufferID(z))
  // CHECK-NEXT: true
}
testAsArray()

import Foundation

func nsArrayOfStrings() -> CocoaArray {
  let src: NativeArray<NSString> = ["foo", "bar", "baz"]

  let ns =  NSArray(
    withObjects: UnsafePointer(src.buffer.elementStorage),
    count: src.count)

  return reinterpretCast(ns) as CocoaArray
}

func testCocoa() {
  println("== Cocoa ==")

  var a = NewArray<NSString>(.Cocoa(nsArrayOfStrings()))
  printSequence(a)
  a += "qux"
  printSequence(a)

  a = NewArray<NSString>(.Cocoa(nsArrayOfStrings()))
  printSequence(a)
  a[1] = "garply"
  printSequence(a)
}
testCocoa()
// CHECK: == Cocoa ==
// CHECK-NEXT: [foo, bar, baz]
// CHECK-NEXT: [foo, bar, baz, qux]
// CHECK-NEXT: [foo, bar, baz]
// CHECK-NEXT: [foo, garply, baz]

func testSlice() {
  println("== Slice ==")
  // CHECK: == Slice ==
  var a0: NativeArray<X> = asArray(X(0)...X(7))

  // Grab the buffer, which we can manipulate without inducing COW, and do some
  // tests on the shared semantics
  var b: NativeArrayBuffer<X> = a0.buffer

  // Slice it
  var bSlice = b[3...5]
  println("<\(bSlice.count)>")
  // CHECK-NEXT: <2>
  printSequence(bSlice)                
  // CHECK-NEXT: [3, 4]

  // bSlice += X(11)..X(13)

  // Writing into b changes bSlice
  b[4] = 41        
  printSequence(bSlice)           // CHECK-NEXT: [3, 41]

  // Writing into bSlice changes b
  bSlice[1] = 42                  // CHECK-NEXT: [3, 42]
  printSequence(bSlice) 
  printSequence(b)                // CHECK-NEXT: [0, 1, 2, 3, 42, 5, 6]

  // Now test Slice itself, which has value semantics
  var a = NewArray<NSString>(.Cocoa(nsArrayOfStrings()))
  
  printSequence(a)                // CHECK-NEXT: [foo, bar, baz]
  
  var aSlice = a[1...3]           // CHECK-NEXT: [bar, baz]
  printSequence(aSlice)  

  // Writing into aSlice doesn't change a
  aSlice[0] = "buzz"              // CHECK-NEXT: [buzz, baz]
  printSequence(aSlice)  

  // And doesn't change a
  printSequence(a)                // CHECK-NEXT: [foo, bar, baz]

  // Appending to aSlice works...
  aSlice += "fodder"              
  println("<\(aSlice.count)>")    // CHECK-NEXT: <3>
  printSequence(aSlice)           // CHECK-NEXT: [buzz, baz, fodder]

  // And doesn't change a
  printSequence(a)                // CHECK-NEXT: [foo, bar, baz]
}
testSlice()

println("leaks = \(xCount)")
// CHECK-NEXT: leaks = 0

// CHECK-NEXT: all done.
println("all done.")

// ${'Local Variables'}:
// eval: (read-only-mode 1)
// End:
