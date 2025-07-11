# Xcode Development Rules for opencode

## Core Principles

### 🚨 CRITICAL: Project File Protection
**NEVER modify `*.xcodeproj` or `*.xcworkspace` files directly without explicit user permission.**

These files contain the project structure and build configuration. Modifying them incorrectly can break the entire project.

### Safe Development Workflow
1. **Read existing code first** - Always examine the current project structure before making changes
2. **Follow existing patterns** - Match the coding style, architecture, and conventions already in use
3. **Test incrementally** - Build and test after each significant change
4. **Use existing frameworks** - Only use libraries and frameworks already included in the project

## File Management Rules

### ✅ SAFE Operations
- **Editing existing Swift files** - Modify `.swift` files that are already part of the project
- **Reading project files** - Examine code, assets, and configuration files
- **Adding assets** - Add images, sounds, or other resources to existing asset catalogs
- **Modifying Info.plist** - Update app configuration through existing plist files

### ⚠️ REQUIRES PERMISSION
Before performing these operations, **ALWAYS ask the user for explicit permission**:
- Adding new Swift files to the project
- Creating new folders or groups
- Adding new frameworks or dependencies
- Modifying project settings or build configurations
- Creating new targets or schemes
- Adding entitlements or capabilities

### 🚫 PROHIBITED Operations
- Direct modification of `.xcodeproj/project.pbxproj`
- Adding files without updating the project structure
- Changing deployment targets without permission
- Modifying signing certificates or provisioning profiles

## XcodeGen Integration

### ⚠️ CRITICAL: This Project Uses XcodeGen
**NEVER modify `*.xcodeproj` or `*.xcworkspace` files directly - they are auto-generated!**

This project uses XcodeGen with `project.yml` configuration. All project structure changes MUST be made through the YAML file.

### Required XcodeGen Workflow
1. **Always modify `project.yml`** - Add new files, targets, settings, or dependencies here
2. **Regenerate project** - Run `xcodegen generate` after any changes to project.yml
3. **Verify changes** - Ensure the generated project builds successfully
4. **Never commit .xcodeproj changes** - Only commit project.yml modifications

### Current Project Structure (from project.yml)
- **bitchat_iOS** - Main iOS app target
- **bitchat_macOS** - Main macOS app target  
- **bitchatShareExtension** - iOS share extension
- **bitchatTests_iOS** - iOS unit tests
- **bitchatTests_macOS** - macOS unit tests

### XcodeGen Commands
```bash
# Check if XcodeGen is available
which xcodegen

# Regenerate project after modifying project.yml
xcodegen generate

# Build iOS version
xcodebuild -scheme "bitchat (iOS)" build

# Build macOS version  
xcodebuild -scheme "bitchat (macOS)" build

# Run iOS tests
xcodebuild -scheme "bitchat (iOS)" test

# Run macOS tests
xcodebuild -scheme "bitchat (macOS)" test
```

### Adding New Files
To add a new Swift file:
1. Create the `.swift` file in the appropriate directory (e.g., `bitchat/`)
2. The file will automatically be included since `project.yml` uses directory-based sources
3. Run `xcodegen generate` to update the project
4. Build to verify the file is properly included

## Swift Development Best Practices

### Code Organization
- **Follow existing architecture** - Match the current MVVM, MVC, or other patterns in use
- **Use existing services** - Leverage current networking, storage, and utility classes
- **Maintain consistency** - Follow naming conventions and code style already established

### Framework Usage
- **Check existing imports** - Only use frameworks already imported in the project
- **Verify availability** - Ensure frameworks are available for the target iOS/macOS versions
- **Follow project patterns** - Use the same approach for similar functionality elsewhere in the app

### Testing Integration
- **Use existing test structure** - Follow the current testing patterns and frameworks
- **Run tests after changes** - Verify that modifications don't break existing functionality
- **Add tests for new features** - Follow the established testing conventions

## Build and Deployment

### Safe Building
```bash
# Clean build folder
xcodebuild clean

# Build for testing
xcodebuild -scheme YourApp -destination 'platform=iOS Simulator,name=iPhone 15' build

# Run tests
xcodebuild test -scheme YourApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Common Issues Prevention
- **Check deployment targets** - Ensure new code is compatible with minimum iOS/macOS versions
- **Verify signing** - Don't modify code signing settings without permission
- **Test on multiple platforms** - If universal app, test on both iOS and macOS
- **Handle deprecations** - Use current APIs and avoid deprecated methods

## Emergency Procedures

### If Project Gets Corrupted
1. **Stop immediately** - Don't make further changes
2. **Check git status** - See what files were modified
3. **Revert if possible** - Use `git checkout` to restore project files
4. **Inform user** - Explain what happened and what was reverted
5. **Request guidance** - Ask user how to proceed safely

### Recovery Commands
```bash
# Check what was changed
git status
git diff

# Revert project file changes (if safe to do so)
git checkout -- *.xcodeproj/

# Restore to last known good state
git stash
# or
git reset --hard HEAD
```

## Communication Protocol

### Before Making Changes
1. **Explain the plan** - Describe what files will be modified
2. **Request permission** - Explicitly ask for approval for project structure changes
3. **Confirm understanding** - Ensure user agrees with the approach

### During Development
1. **Report progress** - Update user on significant milestones
2. **Flag issues early** - Report problems as soon as they're discovered
3. **Verify builds** - Confirm that changes don't break compilation

### After Changes
1. **Summarize modifications** - List what files were changed
2. **Confirm functionality** - Verify that features work as expected
3. **Suggest testing** - Recommend user testing on their target devices

## Example Safe Workflow

```markdown
1. User requests: "Add a new settings screen"

2. opencode response:
   - "I'll add a new settings screen. This will require creating a new Swift file and updating the navigation. May I add a new SettingsView.swift file to the project?"

3. After user approval:
   - Read existing view files to understand patterns
   - Create SettingsView.swift following existing conventions
   - Update navigation in existing files
   - Test that the app builds successfully

4. Report completion:
   - "Added SettingsView.swift with navigation integration. The app builds successfully and the settings screen is accessible from the main menu."
```

## Key Reminders

- **Always read before writing** - Understand the existing codebase structure
- **Ask permission for structural changes** - Don't assume it's okay to add files
- **Follow existing patterns** - Consistency is more important than personal preferences
- **Test frequently** - Build after each significant change
- **Communicate clearly** - Keep user informed of progress and any issues

Remember: It's better to ask for permission and proceed safely than to break a working project.