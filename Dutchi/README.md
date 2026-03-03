# Dutchie - Bill Splitting App

A clean, black and white SwiftUI app for splitting bills with friends.

## Features

### Screen 1 - Upload
- Add receipt photos or connect bank account
- Manual entry for items
- Clean thumbnail grid view

### Screen 2 - People
- Add people manually or from contacts
- Save frequently used groups
- Pre-filled with current user

### Screen 3 - Processing
- Automatic OCR processing of receipts
- Visual progress indicator

### Screen 4 - Review
- Edit transaction details
- Assign payers and split participants
- Mark transactions as personal
- Edit amounts inline

### Screen 5 - Settle & Share
- Optimized settlement calculations
- Copy individual or all payments
- Share settlement summary with payment links

### Profile
- Set name and phone number
- Configure Zelle and Venmo payment links
- Toggle which methods to include when sharing
- Upload profile photo

## Design

- Black and white minimalist design
- Simple icons (no emoji)
- Clean typography
- Card-based layout

## Project Structure

```
Dutchie/
├── App/
│   ├── DutchieApp.swift      # Main app entry
│   ├── AppState.swift         # Global state management
│   └── Router.swift           # Navigation logic
├── Models/
│   ├── Profile.swift          # User profile & payment methods
│   ├── Person.swift           # Person in split group
│   ├── Transaction.swift      # Transaction details
│   ├── Group.swift           # Saved groups
│   └── PaymentLink.swift     # Settlement payment
├── Features/
│   ├── Profile/
│   │   └── ProfileView.swift
│   ├── Upload/
│   │   └── UploadView.swift
│   ├── People/
│   │   └── PeopleView.swift
│   ├── Processing/
│   │   └── ProcessingView.swift
│   ├── Review/
│   │   └── ReviewView.swift
│   └── SettleShare/
│       └── SettleShareView.swift
├── Services/
│   ├── PhotoImportService.swift
│   ├── OCRService.swift
│   ├── TransactionParser.swift
│   ├── SettlementService.swift
│   ├── ShareFormatter.swift
│   └── ContactsService.swift
└── UIComponents/
    ├── AvatarView.swift
    ├── ChipView.swift
    ├── TransactionCardView.swift
    ├── PaymentCardView.swift
    └── ToastView.swift
```

## Setup

### Option 1: Create New Xcode Project (Recommended)

1. Open Xcode
2. Create a new project: **File → New → Project**
3. Select **iOS → App**, click **Next**
4. Configure:
   - Product Name: `Dutchie`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Minimum iOS: **16.0**
5. Click **Create**
6. Delete the default `ContentView.swift` file
7. Drag all files from the downloaded Dutchie folder into your Xcode project
8. When prompted, select:
   - ✅ Copy items if needed
   - ✅ Create groups
   - Target: Dutchie
9. Add the `Info.plist` to your project or manually add these keys to your existing Info.plist:
   - `NSPhotoLibraryUsageDescription`: "We need access to your photos to import receipt images."
   - `NSContactsUsageDescription`: "We need access to your contacts to easily add people to split bills with."
   - `NSCameraUsageDescription`: "We need access to your camera to take photos of receipts."
10. Build and run (⌘R)

### Option 2: Fix Import Issues

⚠️ **CRITICAL**: Make sure you created an **iOS App** project, NOT a macOS or multiplatform project!

If you're getting "No such module 'UIKit'" or "Cannot find UIImage" errors:

1. **Verify it's an iOS project**:
   - Select your project in Xcode (blue icon at top of left sidebar)
   - Under TARGETS, select "Dutchie"
   - Go to "General" tab
   - Check that "Supported Destinations" shows iOS devices/simulators only
   - If it shows macOS, you created the wrong type of project - start over

2. **Set Deployment Target**:
   - In the same General tab
   - Set "Minimum Deployments" to iOS 16.0 or higher

3. **Delete the default ContentView.swift**:
   - This is the #1 cause of "Invalid redeclaration" errors
   - Find it in the left sidebar, right-click → Delete → Move to Trash

4. **Clean and rebuild**:
   - Product → Clean Build Folder (⌘⇧K)
   - Product → Build (⌘B)

### Troubleshooting

**Error: "No such module 'UIKit'"**
- Solution: UIKit is automatically available in SwiftUI projects. Make sure you created an iOS App project (not macOS)
- Check that all files import `SwiftUI` instead of `UIKit`

**Error: Missing capabilities**
- Add required privacy descriptions in Info.plist (see step 9 above)

**Error: Cannot find UIImage/UIPasteboard**
- These types are available in SwiftUI. Ensure your project target is iOS, not macOS

## Usage Flow

1. **Upload**: Add receipt photos or manually enter transactions
2. **People**: Add friends you're splitting with
3. **Processing**: App processes receipts with OCR
4. **Review**: Verify and edit transaction details
5. **Settle**: View optimized settlements and share payment info

## Key Features

- **Smart Settlement**: Minimizes number of payments needed
- **Group Memory**: Saves frequently used groups
- **Flexible Editing**: Edit any transaction detail
- **Multiple Payment Methods**: Support for Zelle and Venmo
- **Privacy**: Toggle which payment methods to share

## Technologies

- SwiftUI
- Vision Framework (OCR)
- Contacts Framework
- PhotosUI
- Share Sheet

## Notes

- All data is stored locally
- OCR processing happens on-device
- Contact access is optional
- Payment method sharing is opt-in
