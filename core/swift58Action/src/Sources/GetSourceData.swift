import MockPowersoftClient
import MockShopifyClient
import ShopifyKit
import PowersoftKit
import Foundation

struct SourceData: Codable{
	let psModelsByModelCode: [String: [PSItem]]
	let psStocksByModelCode: [String: [PSListStockStoresItem]]
	let shProdsByHandle: [String: SHProduct]
	let shStocksByInvID: [Int: InventoryLevel]
}

func GetSourceData()async->SourceData?{
//	guard args.count>1 else {
//		print("Expected 2 string arguments, which are PS and SH server URLs!", " given: ",args.joined())
//		return nil
//	}
//	guard let psURL = URL(string: args[0]), let shURL = URL(string: args[1]) else{
//		print("Error: not valid URLs: \(args[0]) \(args[1])", " given: ",args.joined())
//		return nil
//	}
//	let psURL = URL(string: "http://ms0839.utah.cloudlab.us:8081")!
//	let shURL = URL(string: "http://ms0818.utah.cloudlab.us:8082")!
	let psURL = URL(string: "https://c3f0-62-228-94-47.eu.ngrok.io")!
	let shURL = URL(string: "https://c508-62-228-94-47.eu.ngrok.io")!

	let psClient = MockPsClient(baseURL: psURL)
	let shClient = MockShClient(baseURL: shURL)
	async let psItems = psClient.getAllItems(type: .eCommerceOnly)
	async let shProds = shClient.getAllProducts()
	async let psStocks = psClient.getAllStocks(type: .eCommerceOnly)
	async let shStocks = shClient.getAllInventories()
	guard
	let psItems = await psItems,
	let psStocks = await psStocks,
	let shProds = await shProds,
	let shStocks = await shStocks
	else{
		print("[ERROR] failed to fetch source data!")
		return nil
	}
	print("converting to dictionaries...")
	let models = Dictionary(grouping: psItems, by: {($0.modelCode365 == "") ? $0.getShHandle() : $0.modelCode365})
	
	async let prods = shProds.toDictionary(usingKP: \.handle)
	async let shStockByInvID = shStocks.toDictionary(usingKP: \.inventoryItemID)
	async let psStocksByModelCode = psStocks.toDictionaryArray(usingKP: \.modelCode365)
	
	return await .init(psModelsByModelCode: models, psStocksByModelCode: psStocksByModelCode, shProdsByHandle: prods, shStocksByInvID: shStockByInvID)
}
