import React from 'react';
import {shallow} from 'enzyme';
import EventsTableRow from 'app/components/eventsTableRow';

describe('EventsTableRow', function() {
  beforeEach(function() {
    this.sandbox = sinon.sandbox.create();
  });

  afterEach(function() {
    this.sandbox.restore();
  });

  it('renders', function() {
    let wrapper = shallow(<EventsTableRow />);
    expect(wrapper).toMatchSnapshot();
  });
});
