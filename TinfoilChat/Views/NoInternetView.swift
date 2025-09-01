import SwiftUI

struct NoInternetView: View {
    let retryAction: () -> Void
    
    var body: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                Spacer()
                
                // Icon
                Image(systemName: "wifi.slash")
                    .font(.system(size: 80))
                    .foregroundColor(.gray.opacity(0.8))
                
                VStack(spacing: 12) {
                    // Title
                    Text("No Internet Connection")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white)
                    
                    // Message
                    Text("Please check your internet connection and try again.")
                        .font(.system(size: 17))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                }
                
                Spacer()
                
                // Try Again Button
                Button(action: retryAction) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .medium))
                        Text("Try Again")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .frame(minWidth: 160)
                    .padding(.vertical, 16)
                    .background(Color(red: 0, green: 0.4, blue: 0.4))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                    .frame(height: 100)
            }
            .padding()
        }
        // Match system appearance
        .preferredColorScheme(.dark)
    }
}

#Preview {
    NoInternetView {
        // Preview action
    }
} 