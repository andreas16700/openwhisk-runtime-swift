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

import Foundation
import Dispatch
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public enum URLSessionAsyncErrors: Error {
	case invalidUrlResponse, missingResponseData
}

/// An extension that provides async support for fetching a URL
///
/// Needed because the Linux version of Swift does not support async URLSession yet.
public extension URLSession {

	/// A reimplementation of `URLSession.shared.data(from: url)` required for Linux
	///
	/// - Parameter url: The URL for which to load data.
	/// - Returns: Data and response.
	///
	/// - Usage:
	///
	///     let (data, response) = try await URLSession.shared.asyncData(from: url)
	func asyncData(from url: URL) async throws -> (Data, URLResponse) {
		return try await withCheckedThrowingContinuation { continuation in
			let task = URLSession.shared.dataTask(with: url) { data, response, error in
				fulfillContinuationFromCompletionHandler(continuation: continuation, data: data, response: response, error: error)
			}
			task.resume()
		}
	}
	func asyncData(with request: URLRequest)async throws -> (Data, URLResponse){
		return try await withCheckedThrowingContinuation { continuation in
			let task = URLSession.shared.dataTask(with: request) { data, response, error in
				fulfillContinuationFromCompletionHandler(continuation: continuation, data: data, response: response, error: error)
			}
			task.resume()
		}
	}
}
func fulfillContinuationFromCompletionHandler(continuation: CheckedContinuation<(Data,URLResponse),Error>, data: Data?, response: URLResponse?, error: Error?){
	if let error = error {
		continuation.resume(throwing: error)
		return
	}
	guard let response = response as? HTTPURLResponse else {
		continuation.resume(throwing: URLSessionAsyncErrors.invalidUrlResponse)
		return
	}
	guard let data = data else {
		continuation.resume(throwing: URLSessionAsyncErrors.missingResponseData)
		return
	}
	continuation.resume(returning: (data, response))
}

class Whisk {

	static var baseUrl = ProcessInfo.processInfo.environment["__OW_API_HOST"]
	static var apiKey = ProcessInfo.processInfo.environment["__OW_API_KEY"]
	// This will allow user to modify the default JSONDecoder and JSONEncoder used by epilogue
	static var jsonDecoder = JSONDecoder()
	static var jsonEncoder = JSONEncoder()

	class func invoke(actionNamed action : String, withParameters params : [String:Any], blocking: Bool = true) async -> [String:Any] {
		let parsedAction = parseQualifiedName(name: action)
		let strBlocking = blocking ? "true" : "false"
		let path = "/api/v1/namespaces/\(parsedAction.namespace)/actions/\(parsedAction.name)?blocking=\(strBlocking)"

		return await sendWhiskRequest(uriPath: path, params: params, method: "POST")
	}

	class func trigger(eventNamed event : String, withParameters params : [String:Any]) async -> [String:Any] {
		let parsedEvent = parseQualifiedName(name: event)
		let path = "/api/v1/namespaces/\(parsedEvent.namespace)/triggers/\(parsedEvent.name)?blocking=true"

		return await sendWhiskRequest(uriPath: path, params: params, method: "POST")
	}

	class func createTrigger(triggerNamed trigger: String, withParameters params : [String:Any]) async -> [String:Any] {
		let parsedTrigger = parseQualifiedName(name: trigger)
		let path = "/api/v1/namespaces/\(parsedTrigger.namespace)/triggers/\(parsedTrigger.name)"
		return await sendWhiskRequest(uriPath: path, params: params, method: "PUT")
	}

	class func createRule(ruleNamed ruleName: String, withTrigger triggerName: String, andAction actionName: String) async -> [String:Any] {
		let parsedRule = parseQualifiedName(name: ruleName)
		let path = "/api/v1/namespaces/\(parsedRule.namespace)/rules/\(parsedRule.name)"
		let params = ["trigger":triggerName, "action":actionName]
		return await sendWhiskRequest(uriPath: path, params: params, method: "PUT")
	}

	private class func sendWhiskRequest(uriPath: String, params : [String:Any], method: String) async -> [String:Any]{
		guard let encodedPath = uriPath.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) else {
			return ["error": "Error encoding uri path to make openwhisk REST call."]
		}

		let urlStr = "\(baseUrl!)\(encodedPath)"

		guard let url = URL(string: urlStr) else {
			return ["error": "Error constructing url with \(urlStr)"]
		}
		var request = URLRequest(url: url)
		request.httpMethod = method

		do {
			request.addValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try JSONSerialization.data(withJSONObject: params)

			let loginData: Data = apiKey!.data(using: String.Encoding.utf8, allowLossyConversion: false)!
			let base64EncodedAuthKey  = loginData.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
			request.addValue("Basic \(base64EncodedAuthKey)", forHTTPHeaderField: "Authorization")
			let session = URLSession(configuration: URLSessionConfiguration.default)
			let (data, _) = try await session.asyncData(with: request)
			do {
				//let outputStr  = String(data: data, encoding: String.Encoding.utf8) as String!
				//print(outputStr)
				let respJson = try JSONSerialization.jsonObject(with: data)
				if respJson is [String:Any] {
					return respJson as! [String:Any]
				} else {
					return ["error":" response from server is not a dictionary"]
				}
			} catch {
				return ["error":"Error creating json from response: \(error)"]
			}
		} catch {
			return ["error":"Got error creating params body: \(error)"]
		}
	}


	// separate an OpenWhisk qualified name (e.g. "/whisk.system/samples/date")
	// into namespace and name components
	private class func parseQualifiedName(name qualifiedName : String) -> (namespace : String, name : String) {
		let defaultNamespace = "_"
		let delimiter = "/"

		let segments :[String] = qualifiedName.components(separatedBy: delimiter)

		if segments.count > 2 {
			return (segments[1], Array(segments[2..<segments.count]).joined(separator: delimiter))
		} else if segments.count == 2 {
			// case "/action" or "package/action"
			let name = qualifiedName.hasPrefix(delimiter) ? segments[1] : segments.joined(separator: delimiter)
			return (defaultNamespace, name)
		} else {
			return (defaultNamespace, segments[0])
		}
	}

}
