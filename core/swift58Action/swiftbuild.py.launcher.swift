/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Imports
import Foundation
#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

func _whisk_print(message: String, title: String){
	let str =  "{\"\(title)\":\"\(message)\"}\n"
	print(str)
	_whisk_print_buffer(jsonString: str)
}
func _whisk_print_error(message: String, error: Error?){

	var errStr =  "{\"error\":\"\(message)\"}\n"
	if let error = error {
		errStr = "{\"error\":\"\(message) \(error.localizedDescription)\"\n}"
	}
print(errStr)
	_whisk_print_buffer(jsonString: errStr)
}
func _whisk_print_result(jsonData: Data){
	let jsonString = String(data: jsonData, encoding: .utf8)!
	print("Result :"+jsonString)
	_whisk_print_buffer(jsonString: jsonString)
}
func _whisk_print_buffer(jsonString: String){
	var buf : [UInt8] = Array(jsonString.utf8)
	buf.append(10)
	fflush(stdout)
	fflush(stderr)
	write(3, buf, buf.count)
}

// snippet of code "injected" (wrapper code for invoking traditional main)


//any input any output
func _run_main(mainFunction: (Any) async throws -> Any, json: Data?) async -> Void {
	guard let json else {_whisk_print_error(message: "No input given but function requires input!", error: nil);return}
	guard let input = handleAndParseInput(json: json) else {return}
	guard let result = await handleAndRunThrowingFunc({try await mainFunction(input)}) else {return}
	handleOutput(result: result)
}

//

// Codable main signature input Codable
func _run_main<In: Decodable, Out: Encodable>(mainFunction: (In) async throws -> Out?, json: Data?)async {
	guard let json else {_whisk_print_error(message: "No input given but function requires input!", error: nil);return}
	guard let input = handleAndParseInput(json: json, type: In.self) else {return}
	guard let result = await handleAndRunThrowingFunc({return try await mainFunction(input)})else{return}
	handleEncodableOutput(result: result)
}

// Codable main signature no input
func _run_main<Out: Encodable>(mainFunction: () async throws -> Out?, json: Data? = nil) async rethrows{
	guard let result = await handleAndRunThrowingFunc(mainFunction)else{return}
	handleEncodableOutput(result: result)
}

//helper functions
private func handleAndRunThrowingFunc<T>(_ action: ()async throws->T?)async->T?{
	do{
		return try await action()
	}catch{
		_whisk_print_error(message: "Failed running function with error: ", error: error)
		return nil
	}
}
private func handleAndParseInput(json: Data)->Any?{
	do{
		let parsed = try JSONSerialization.jsonObject(with: json, options: [])
		return parsed
	} catch {
		_whisk_print_error(message: "Failed to execute action handler with error:", error: error)
		return nil
	}
}
private func handleAndParseInput<Input: Decodable>(json: Data, type: Input.Type)->Input?{
	do{
		let input = try Whisk.jsonDecoder.decode(Input.self, from: json)
		return input
	} catch let error as DecodingError {
		_whisk_print_error(message: "JSONDecoder failed to decode JSON string \(String(data: json, encoding: .utf8)!.replacingOccurrences(of: "\"", with: "\\\"")) to Codable type:", error: error)
		return nil
	} catch {
		_whisk_print_error(message: "Failed to execute action handler with error:", error: error)
		return nil
	}
}
private func handleOutput(result: Any){
	if JSONSerialization.isValidJSONObject(result) {
		do {
			let jsonData = try JSONSerialization.data(withJSONObject: result, options: [])
			_whisk_print_result(jsonData: jsonData)
		} catch {
			_whisk_print_error(message: "Failed to encode Dictionary type to JSON string:", error: error)
		}
	} else {
		_whisk_print_error(message: "Error serializing JSON, data does not appear to be valid JSON", error: nil)
	}
}
private func handleEncodableOutput<Out: Encodable>(result: Out?){
	guard let result else{
		_whisk_print_error(message: "Action handler callback did not return response or error.", error: nil)
		return
	}
	do {
		let jsonData = try Whisk.jsonEncoder.encode(result)
		_whisk_print_result(jsonData: jsonData)
	} catch let error as EncodingError {
		_whisk_print_error(message: "JSONEncoder failed to encode Codable type to JSON string:", error: error)
		return
	} catch {
		_whisk_print_error(message: "Failed to execute action handler with error:", error: error)
		return
	}
}
// snippets of code "injected", depending on the type of function the developer
// wants to use traditional vs codable







