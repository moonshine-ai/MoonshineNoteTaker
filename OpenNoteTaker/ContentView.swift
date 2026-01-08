/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's main view.
*/

import SwiftUI
import ScreenCaptureKit
import OSLog
import Combine

struct ContentView: View {
    
    @State var userStopped = false
    @State var isUnauthorized = false
    
    @StateObject var screenRecorder = ScreenRecorder()
    
    var body: some View {
        screenRecorder.capturePreview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(screenRecorder.contentSize, contentMode: .fit)
            .padding(8)
            .overlay {
                if userStopped {
                    Image(systemName: "nosign")
                        .font(.system(size: 250, weight: .bold))
                        .foregroundColor(Color(white: 0.3, opacity: 1.0))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.0, opacity: 0.5))
                }
            }
        .overlay {
            if isUnauthorized {
                VStack() {
                    Spacer()
                    VStack {
                        Text("No screen recording permission.")
                            .font(.largeTitle)
                            .padding(.top)
                        Text("Open System Settings and go to Privacy & Security > Screen Recording to grant permission.")
                            .font(.title2)
                            .padding(.bottom)
                    }
                    .frame(maxWidth: .infinity)
                    .background(.red)
                    
                }
            }
        }
        .navigationTitle("Open Note Taker")
        .onAppear {
            Task {
                if await screenRecorder.canRecord {
                    await screenRecorder.start()
                } else {
                    isUnauthorized = true
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
