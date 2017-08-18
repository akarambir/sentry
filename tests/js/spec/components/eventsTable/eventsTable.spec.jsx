import React from 'react';
import {shallow} from 'enzyme';
import EventsTable from 'app/components/eventsTable';

describe('EventsTable', function() {
  beforeEach(function() {
    this.sandbox = sinon.sandbox.create();
  });

  afterEach(function() {
    this.sandbox.restore();
  });

  it('renders', function() {
    let wrapper = shallow(<EventsTable />);
    expect(wrapper).toMatchSnapshot();
  });
});
