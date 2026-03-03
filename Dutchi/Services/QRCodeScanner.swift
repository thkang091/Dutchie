import UIKit
import Vision

class QRCodeScanner {
    
    /// Scans a QR code image and extracts the payment link
    /// - Parameter image: The QR code image to scan
    /// - Returns: The extracted URL string, or nil if no QR code found
    static func extractPaymentLink(from image: UIImage) -> String? {
        guard let cgImage = image.cgImage else {
            print("❌ QRCodeScanner: Failed to get CGImage from UIImage")
            return nil
        }
        
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let results = request.results, !results.isEmpty else {
                print("❌ QRCodeScanner: No QR codes detected in image")
                return nil
            }
            
            print("✅ QRCodeScanner: Found \(results.count) QR code(s)")
            
            // Try all detected QR codes
            for (index, result) in results.enumerated() {
                if let payload = result.payloadStringValue {
                    print("📱 QRCodeScanner: QR #\(index + 1) payload: \(payload.prefix(100))...")
                    
                    // Check if it's a valid payment link
                    if isZelleLink(payload) || isVenmoLink(payload) {
                        print("✅ QRCodeScanner: Valid payment link found!")
                        return payload
                    } else {
                        print("⚠️ QRCodeScanner: QR #\(index + 1) is not a payment link")
                    }
                }
            }
            
            print("❌ QRCodeScanner: No valid payment links found in any QR codes")
            return nil
            
        } catch {
            print("❌ QRCodeScanner: Scanning failed - \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Validates if a string is a valid Zelle payment link
    /// - Parameter link: The link to validate
    /// - Returns: True if it's a valid Zelle link
    static func isZelleLink(_ link: String) -> Bool {
        let lowercased = link.lowercased()
        
        let isZelle = lowercased.contains("enroll.zellepay.com") ||
                      lowercased.contains("zellepay.com") ||
                      lowercased.contains("chase.com/personal/zelle") ||
                      lowercased.contains("bankofamerica.com/zelle") ||
                      lowercased.contains("wellsfargo.com/zelle") ||
                      lowercased.contains("usbank.com/zelle") ||
                      lowercased.contains("pnc.com/zelle") ||
                      lowercased.contains("capitalone.com/zelle") ||
                      lowercased.contains("zelle://")
        
        if isZelle {
            print("✅ QRCodeScanner: Validated as Zelle link")
            
            // Additional validation: check if it has the data parameter (for QR codes)
            if lowercased.contains("data=") {
                print("✅ QRCodeScanner: Zelle QR link contains data parameter")
            }
        }
        
        return isZelle
    }
    
    /// Validates if a string is a valid Venmo payment link
    /// - Parameter link: The link to validate
    /// - Returns: True if it's a valid Venmo link
    static func isVenmoLink(_ link: String) -> Bool {
        let lowercased = link.lowercased()
        
        let isVenmo = lowercased.contains("venmo.com") ||
                      lowercased.contains("venmo://")
        
        if isVenmo {
            print("✅ QRCodeScanner: Validated as Venmo link")
        }
        
        return isVenmo
    }
    
    /// Extracts and decodes the Zelle token/data from a Zelle QR link
    /// - Parameter link: The full Zelle link
    /// - Returns: Decoded JSON data if found and valid
    static func extractZelleData(from link: String) -> [String: Any]? {
        guard let url = URL(string: link),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value else {
            print("⚠️ QRCodeScanner: Could not extract data parameter from Zelle link")
            return nil
        }
        
        // The data parameter is Base64 encoded JSON
        guard let decodedData = Data(base64Encoded: dataParam),
              let jsonString = String(data: decodedData, encoding: .utf8),
              let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("⚠️ QRCodeScanner: Could not decode Base64 data parameter")
            return nil
        }
        
        print("✅ QRCodeScanner: Successfully decoded Zelle QR data")
        if let action = json["action"] as? String,
           let token = json["token"] as? String,
           let name = json["name"] as? String {
            print("   - Action: \(action)")
            print("   - Token: \(token)")
            print("   - Name: \(name)")
        }
        
        return json
    }
    
    /// Validates that a Zelle QR code link is complete and valid
    /// - Parameter link: The Zelle link to validate
    /// - Returns: True if the link is valid and complete
    static func validateZelleQRLink(_ link: String) -> Bool {
        // Check basic structure
        guard isZelleLink(link) else {
            print("❌ QRCodeScanner: Not a Zelle link")
            return false
        }
        
        // For QR code links, verify the data parameter exists and is valid
        if link.contains("data=") {
            if let data = extractZelleData(from: link) {
                // Check for required fields
                if data["token"] != nil && data["action"] != nil {
                    print("✅ QRCodeScanner: Valid Zelle QR link with complete data")
                    return true
                } else {
                    print("❌ QRCodeScanner: Zelle data missing required fields")
                    return false
                }
            } else {
                print("❌ QRCodeScanner: Could not decode Zelle QR data")
                return false
            }
        }
        
        // For deep links (zelle://), they're valid as-is
        if link.lowercased().hasPrefix("zelle://") {
            print("✅ QRCodeScanner: Valid Zelle deep link")
            return true
        }
        
        print("✅ QRCodeScanner: Valid Zelle link (general)")
        return true
    }
}
