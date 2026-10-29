package wakilcore

import "strconv"

// DefaultMessageWakes is Agents woken by messages when neither the organisation nor the project
// sets it (workspaces piece 4, decision 16): message-woken turns a workspace gets per operator
// message.
const DefaultMessageWakes = 8

// maxMessageWakes bounds the setting; 0 means messages never wake an agent.
const maxMessageWakes = 99

// messageWakesValue turns a patch's value into what is stored: nil leaves the field, -1 clears it
// (the organisation's default, or the project's inheritance), 0–99 sets it. Anything else is
// refused whole.
func messageWakesValue(n int) (*int, error) {
	if n == -1 {
		return nil, nil
	}
	if n < 0 || n > maxMessageWakes {
		return nil, UserError("Agents woken by messages must be a whole number from 0 to " +
			strconv.Itoa(maxMessageWakes) + " (0 never wakes an agent), not " + strconv.Itoa(n))
	}
	v := n
	return &v, nil
}

// resolvedMessageWakes is the organisation's value, or the default when it sets none.
func resolvedMessageWakes(o *int) int {
	if o == nil {
		return DefaultMessageWakes
	}
	return *o
}
