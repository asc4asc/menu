#!/usr/bin/python3

import os
import pickle

class RingBuffer:
    def __init__(self, size, filename):
        self.size = size
        self.buffer = []
        self.index = 0
        self.filename = filename
        self.load_buffer()

    def add(self, number):
        if number in self.buffer:
            return False  # Nummer existiert bereits im Puffer
        if len(self.buffer) < self.size:
            self.buffer.append(number)
        else:
            self.buffer[self.index] = number
        self.index = (self.index + 1) % self.size
        self.save_buffer()
        return True

    def save_buffer(self):
        with open(self.filename, 'wb') as f:
            pickle.dump((self.buffer, self.index), f)

    def load_buffer(self):
        if os.path.exists(self.filename):
            with open(self.filename, 'rb') as f:
                self.buffer, self.index = pickle.load(f)

    def __str__(self):
        return str(self.buffer)

# Erstellen eines Ringpuffers mit einer maximalen Größe von 100 und einer Datei zum Speichern des Zustands
ring_buffer = RingBuffer(100, 'ring_buffer.pkl')

# Beispielhafte Nutzung
numbers_to_add = [12345678, 23456789, 34567890, 45678901, 56789012, 67890123, 78901234, 89012345, 90123456, 12345678]

for number in numbers_to_add:
    if ring_buffer.add(number):
        print(f"Nummer {number} wurde dem Puffer hinzugefügt.")
    else:
        print(f"Nummer {number} existiert bereits im Puffer.")

print("Endgültiger Pufferzustand:", ring_buffer)
