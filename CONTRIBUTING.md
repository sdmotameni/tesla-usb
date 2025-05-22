# Contributing to Tesla USB Dashcam Archiver

Thank you for your interest in contributing to the Tesla USB Dashcam Archiver project! This document provides guidelines and instructions for contributing.

## Code of Conduct

Please be respectful and considerate of others when contributing to this project. We aim to foster an inclusive and welcoming community.

## How to Contribute

### Reporting Bugs

If you find a bug, please create an issue on GitHub with the following information:

- A clear, descriptive title
- Steps to reproduce the issue
- Expected behavior vs. actual behavior
- Your system information (Raspberry Pi model, OS version, etc.)
- Any relevant logs or error messages

### Suggesting Enhancements

We welcome suggestions for improving the project! Please create an issue with:

- A clear description of your proposed enhancement
- The rationale behind it (why it would be useful)
- Any implementation ideas you may have

### Pull Requests

1. Fork the repository
2. Create a new branch for your feature or bugfix (`git checkout -b feature/your-feature-name`)
3. Make your changes
4. Test your changes thoroughly
5. Commit your changes (`git commit -m 'Add some feature'`)
6. Push to your branch (`git push origin feature/your-feature-name`)
7. Open a Pull Request

## Development Guidelines

### Code Style

- Follow the existing code style in the project
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions small and focused on a single task

### Bash Scripting Best Practices

- Always use `set -euo pipefail` at the beginning of scripts
- Quote variables to prevent word splitting
- Use shellcheck to validate your scripts
- Document functions and complex sections with comments

### Testing

Before submitting a pull request, please test your changes:

- Test on a Raspberry Pi if possible
- Verify that the script still works with the Tesla USB setup
- Check for any regressions in functionality

## Project Structure

- `/scripts` - Shell scripts for the project
- `/config` - Configuration files
- `/etc` - Systemd service and timer files
- `/docs` - Documentation

## Getting Help

If you need help or have questions, please:

1. Check the README.md and existing documentation
2. Look for existing issues that might address your question
3. Create a new issue with your question if none exist

Thank you for contributing to the Tesla USB Dashcam Archiver project!
