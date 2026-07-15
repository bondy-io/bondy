# CHANGELOG

## 0.4.0
### Changes:
- Added `callback_args` field to support extra arguments passed to callback functions
- Updated type definitions to include callback_args => list()
- Modified call_callback/3 function to prepend extra args to callback function arguments
- Maintained full backward compatibility with existing callback_mod implementations